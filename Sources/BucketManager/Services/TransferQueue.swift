import Foundation

@MainActor
final class TransferQueue {
    private(set) var tasks: [TransferTask] = []

    var onChange: (() -> Void)?
    var onLog: ((String) -> Void)?
    var onFinished: (() -> Void)?

    private let service = S3Service.shared
    private let multipartStore: MultipartUploadStore
    private let stateStore: TransferQueueStore
    private let temporaryRegistry: DownloadTempRegistry
    private let credentialProvider: ((UUID) -> (Account, String)?)?
    private let maxConcurrent = 4
    private var credentials: [UUID: (Account, String)] = [:]
    private struct CopyCredentials {
        let source: (Account, String)
        let destination: (Account, String)
    }
    private var copyCredentials: [UUID: CopyCredentials] = [:]
    private var workTasks: [UUID: Task<Void, Never>] = [:]
    private var workGeneration: [UUID: Int] = [:]
    private var lastSample: [UUID: (at: Date, bytes: Int64)] = [:]
    private var lastEmit: Date = .distantPast
    private var persistenceTask: Task<Void, Never>?
    private var isDemoMode = false
    private var isPumping = false
    private var needsPump = false

    init(
        multipartStore: MultipartUploadStore = .shared,
        stateStore: TransferQueueStore = .shared,
        temporaryRegistry: DownloadTempRegistry = .shared,
        credentialProvider: ((UUID) -> (Account, String)?)? = nil
    ) {
        self.multipartStore = multipartStore
        self.stateStore = stateStore
        self.temporaryRegistry = temporaryRegistry
        self.credentialProvider = credentialProvider
        restorePersistedTasks()
        cleanOrphanDownloadTemps()
    }

    private func cleanOrphanDownloadTemps() {
        var active = Set<String>()
        for task in tasks where [.queued, .running, .paused, .failed].contains(task.status) {
            switch task.direction {
            case .download:
                active.insert(S3Service.downloadTemporaryURL(for: task.localURL).path)
            case .copy where S3Service.isCopyTemporaryURL(task.localURL):
                active.insert(task.localURL.path)
                active.insert(S3Service.downloadTemporaryURL(for: task.localURL).path)
            case .upload, .copy:
                break
            }
        }
        for path in active where FileManager.default.fileExists(atPath: path) {
            temporaryRegistry.register(URL(fileURLWithPath: path))
        }
        temporaryRegistry.cleanup(active: active)
    }

    var runningCount: Int { tasks.filter { $0.status == .running }.count }
    var queuedCount: Int { tasks.filter { $0.status == .queued }.count }
    var stoppedCount: Int { tasks.filter { $0.status == .paused }.count }
    var failedCount: Int { tasks.filter { $0.status == .failed }.count }

    var totalBytes: Int64 { tasks.reduce(0) { $0 + $1.size } }
    var doneBytes: Int64 { tasks.reduce(0) { $0 + $1.bytesDone } }
    var aggregateSpeed: Double { tasks.filter { $0.status == .running }.reduce(0) { $0 + $1.speed } }

    private func restorePersistedTasks() {
        tasks = stateStore.load().compactMap { record in
            guard record.status != .completed, record.status != .canceled else { return nil }
            var task = TransferTask(
                direction: record.direction,
                bucket: record.bucket,
                key: record.key,
                localURL: URL(fileURLWithPath: record.localPath),
                size: record.size
            )
            task.id = record.id
            task.accountID = record.accountID
            task.destinationAccountID = record.destinationAccountID
            task.destinationBucket = record.destinationBucket
            task.destinationKey = record.destinationKey
            task.moveSource = record.moveSource ?? false
            task.sourceETag = record.sourceETag
            task.destinationUploadID = record.destinationUploadID
            task.sourceModifiedAt = record.fileModified
            task.isRestored = true
            task.speed = 0
            task.startedAt = nil
            task.finishedAt = nil
            task.error = record.error
            var invalidCopy = false
            if record.direction == .copy {
                let hasDestination = record.destinationAccountID != nil
                    && record.destinationBucket?.isEmpty == false
                    && record.destinationKey?.isEmpty == false
                if hasDestination && S3Service.isCopyTemporaryURL(task.localURL) {
                    try? FileManager.default.removeItem(at: task.localURL)
                    try? FileManager.default.removeItem(
                        at: S3Service.downloadTemporaryURL(for: task.localURL)
                    )
                } else {
                    invalidCopy = true
                }
                task.bytesDone = 0
            } else if record.direction == .download {
                task.downloadETag = record.downloadETag
                let temporary = S3Service.downloadTemporaryURL(for: task.localURL)
                let attributes = try? FileManager.default.attributesOfItem(atPath: temporary.path)
                let temporarySize = (attributes?[.size] as? NSNumber)?.int64Value ?? 0
                if record.downloadETag != nil, temporarySize > 0 {
                    task.bytesDone = min(max(0, record.bytesDone), temporarySize)
                } else {
                    task.bytesDone = 0
                }
            } else {
                task.bytesDone = min(max(0, record.bytesDone), record.size)
            }
            switch record.status {
            case .queued, .running:
                task.status = .paused
            default:
                task.status = record.status
            }
            if record.direction == .upload,
               record.status == .queued || record.status == .running || record.status == .paused {
                let attributes = try? FileManager.default.attributesOfItem(atPath: record.localPath)
                let actualSize = (attributes?[.size] as? NSNumber)?.int64Value
                let actualModified = (attributes?[.modificationDate] as? Date)?.timeIntervalSince1970
                if attributes == nil {
                    task.status = .failed
                    task.bytesDone = 0
                    task.error = "Source file is no longer available; re-add it to upload."
                } else if actualSize != record.size
                            || (record.fileModified.flatMap { expected in
                                actualModified.map { abs($0 - expected) > 0.01 }
                            } ?? false) {
                    task.status = .failed
                    task.bytesDone = 0
                    task.error = "Source file changed since the upload was queued; re-add it to upload."
                }
            }
            if invalidCopy {
                task.status = .failed
                task.error = "Copy task is missing destination information or has an invalid staging path."
            }
            return task
        }
    }

    // MARK: - Enqueue

    func enqueueUpload(account: Account, secret: String, bucket: String, key: String, url: URL) {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        let size = (attributes?[.size] as? NSNumber)?.int64Value ?? 0
        var task = TransferTask(direction: .upload, bucket: bucket, key: key, localURL: url, size: size)
        task.accountID = account.id
        task.sourceModifiedAt = (attributes?[.modificationDate] as? Date)?.timeIntervalSince1970
        if attributes == nil {
            task.status = .failed
            task.error = "Source file is not readable; re-add it to upload."
            tasks.append(task)
            log("Could not queue upload \(key): source file is unavailable")
            change()
            return
        }
        task.status = .queued
        tasks.append(task)
        credentials[task.id] = (account, secret)
        log("Queued upload \(key) (\(size.byteString))")
        change()
        pump()
    }

    func enqueueDownload(account: Account, secret: String, bucket: String, key: String, size: Int64, to url: URL) {
        var task = TransferTask(direction: .download, bucket: bucket, key: key, localURL: url, size: size)
        task.accountID = account.id
        task.status = .queued
        tasks.append(task)
        credentials[task.id] = (account, secret)
        log("Queued download \(key) (\(size.byteString))")
        change()
        pump()
    }

    func enqueueCopy(
        sourceAccount: Account,
        sourceSecret: String,
        sourceBucket: String,
        sourceKey: String,
        sourceSize: Int64,
        sourceETag: String?,
        destinationAccount: Account,
        destinationSecret: String,
        destinationBucket: String,
        destinationKey: String,
        move: Bool
    ) {
        var task = TransferTask(
            direction: .copy,
            bucket: sourceBucket,
            key: sourceKey,
            localURL: S3Service.copyTemporaryURL(),
            size: max(0, sourceSize)
        )
        task.accountID = sourceAccount.id
        task.destinationAccountID = destinationAccount.id
        task.destinationBucket = destinationBucket
        task.destinationKey = destinationKey
        task.sourceETag = sourceETag
        task.moveSource = move
        task.status = .queued
        tasks.append(task)
        copyCredentials[task.id] = CopyCredentials(
            source: (sourceAccount, sourceSecret),
            destination: (destinationAccount, destinationSecret)
        )
        temporaryRegistry.register(task.localURL)
        temporaryRegistry.register(S3Service.downloadTemporaryURL(for: task.localURL))
        log("Queued \(move ? "move" : "copy") \(sourceBucket)/\(sourceKey) to \(destinationBucket)/\(destinationKey)")
        change()
        pump()
    }

    // MARK: - Demo data (snapshot/self-test only)

    func seedDemoTasks() {
        isDemoMode = true
        let now = Date()
        let samples: [(String, Int64, Double, TransferTask.Status, Double)] = [
            ("Uploading file /Users/me/Pictures/IMG_7089.JPG to photos/IMG_7089.JPG", 4_372_142, 0.7842, .running, 1_930_000),
            ("Uploading file /Users/me/Pictures/IMG_7090.JPG to photos/IMG_7090.JPG", 3_890_204, 0.6418, .running, 2_280_000),
            ("Downloading photos/IMG_7091.JPG to /Users/me/Downloads/IMG_7091.JPG", 4_677_914, 0.9155, .running, 1_850_000),
            ("Uploading file /Users/me/Pictures/IMG_7092.JPG to photos/IMG_7092.JPG", 4_110_336, 0.4873, .running, 2_420_000),
            ("Downloading photos/IMG_7093.JPG to /Users/me/Downloads/IMG_7093.JPG", 4_571_136, 0.8306, .running, 2_020_000),
            ("Uploading file /Users/me/Pictures/IMG_7094.JPG to photos/IMG_7094.JPG", 3_837_952, 0.3528, .running, 1_960_000),
            ("Downloading photos/IMG_7095.JPG to /Users/me/Downloads/IMG_7095.JPG", 4_938_752, 0.5764, .queued, 0),
            ("Uploading file /Users/me/Pictures/IMG_7096.JPG to photos/IMG_7096.JPG", 4_267_008, 0.7211, .queued, 0)
        ]
        tasks = samples.map { title, size, progress, status, speed in
            var task = TransferTask(
                direction: title.hasPrefix("Uploading") ? .upload : .download,
                bucket: "photos",
                key: String(title.split(separator: " ").last ?? "IMG_7089.JPG"),
                localURL: URL(fileURLWithPath: "/Users/me/Pictures/IMG_7089.JPG"),
                size: size
            )
            task.bytesDone = Int64(Double(size) * progress)
            task.status = status
            task.speed = speed
            task.startedAt = now.addingTimeInterval(-3)
            return task
        }
        onChange?()
    }

    // MARK: - Controls

    func stop(id: UUID) {
        guard let index = index(of: id) else { return }
        if tasks[index].status == .running {
            tasks[index].status = .paused
            tasks[index].speed = 0
            workTasks[id]?.cancel()
            log("Stopped \(tasks[index].key)")
            let auditAccount = credentials[id]?.0 ?? copyCredentials[id]?.source.0
            audit("transfer.paused", task: tasks[index], account: auditAccount, outcome: "success")
            if credentialProvider != nil {
                credentials[id] = nil
                copyCredentials[id] = nil
            }
        } else if tasks[index].status == .queued {
            tasks[index].status = .paused
            let auditAccount = credentials[id]?.0 ?? copyCredentials[id]?.source.0
            audit("transfer.paused", task: tasks[index], account: auditAccount, outcome: "success")
            if credentialProvider != nil {
                credentials[id] = nil
                copyCredentials[id] = nil
            }
        }
        change()
    }

    func cancel(id: UUID) {
        guard let index = index(of: id) else { return }
        let wasRunning = tasks[index].status == .running
        let task = tasks[index]
        let credentials = credentials[id]
        let copy = copyCredentials[id]
        tasks[index].status = .canceled
        tasks[index].speed = 0
        tasks[index].finishedAt = Date()
        let work = workTasks[id]
        work?.cancel()
        workTasks[id] = nil
        workGeneration[id] = nil
        lastSample[id] = nil
        self.credentials[id] = nil
        let auditAccount = credentials?.0 ?? copyCredentials[id]?.source.0
        copyCredentials[id] = nil
        audit("transfer.canceled", task: task, account: auditAccount, outcome: "success")
        if task.direction == .upload, let credentials {
            let store = multipartStore
            Task {
                await work?.value
                await self.service.abortMultipart(
                    account: credentials.0,
                    secret: credentials.1,
                    bucket: task.bucket,
                    key: task.key,
                    store: store
                )
            }
        } else if task.direction == .download {
            let temporary = S3Service.downloadTemporaryURL(for: task.localURL)
            if let work {
                Task {
                    await work.value
                    try? FileManager.default.removeItem(at: temporary)
                    self.temporaryRegistry.unregister(temporary)
                }
            } else {
                try? FileManager.default.removeItem(at: temporary)
                temporaryRegistry.unregister(temporary)
            }
        } else if task.direction == .copy {
            Task {
                await work?.value
                self.cleanupCopyTemporary(task)
                if let copy {
                    self.abortCopyMultipart(task: task, credentials: copy)
                }
            }
        }
        log("Canceled \(task.key)")
        if wasRunning { pump() }
        change()
    }

    func stopAll() {
        for task in tasks where task.status == .running { stop(id: task.id) }
        for task in tasks where task.status == .queued { stop(id: task.id) }
    }

    func cancelAll() {
        for task in tasks where task.status == .running || task.status == .queued || task.status == .paused {
            cancel(id: task.id)
        }
    }

    func startAll() {
        for index in tasks.indices {
            switch tasks[index].status {
            case .paused, .failed:
                tasks[index].status = .queued
                tasks[index].error = nil
                tasks[index].startedAt = nil
                tasks[index].finishedAt = nil
            default:
                break
            }
        }
        change()
        pump()
    }

    func retry(id: UUID) {
        guard let index = index(of: id),
              tasks[index].status == .failed || tasks[index].status == .paused else { return }
        tasks[index].status = .queued
        tasks[index].error = nil
        tasks[index].startedAt = nil
        tasks[index].finishedAt = nil
        change()
        pump()
    }

    func clearFinished() {
        let finished = tasks.filter { $0.status == .completed || $0.status == .canceled }
        for task in finished {
            credentials[task.id] = nil
            copyCredentials[task.id] = nil
            clearRuntimeState(for: task.id)
        }
        tasks.removeAll { $0.status == .completed || $0.status == .canceled }
        change()
    }

    func flushPersistence() {
        persistenceTask?.cancel()
        persistenceTask = nil
        guard !isDemoMode else { return }
        let records = tasks.compactMap { task -> PersistedTransferTask? in
            guard let accountID = task.accountID else { return nil }
            guard task.status != .completed, task.status != .canceled else { return nil }
            let persistedStatus: TransferTask.Status
            switch task.status {
            case .running, .queued: persistedStatus = .paused
            default: persistedStatus = task.status
            }
            return PersistedTransferTask(
                id: task.id,
                accountID: accountID,
                direction: task.direction,
                bucket: task.bucket,
                key: task.key,
                localPath: task.localURL.path,
                size: task.size,
                bytesDone: task.bytesDone,
                status: persistedStatus,
                error: task.error.map { LogRedactor.message($0) },
                fileModified: task.sourceModifiedAt,
                downloadETag: task.downloadETag,
                destinationAccountID: task.destinationAccountID,
                destinationBucket: task.destinationBucket,
                destinationKey: task.destinationKey,
                moveSource: task.moveSource,
                sourceETag: task.sourceETag,
                destinationUploadID: task.destinationUploadID
            )
        }
        stateStore.save(records)
    }

    private func schedulePersistence() {
        guard !isDemoMode, persistenceTask == nil else { return }
        persistenceTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard !Task.isCancelled else { return }
            self?.flushPersistence()
        }
    }

    // MARK: - Pumping

    private func pump() {
        guard !isPumping else {
            needsPump = true
            return
        }
        isPumping = true
        defer {
            isPumping = false
            if needsPump {
                needsPump = false
                pump()
            }
        }
        var running = tasks.filter { $0.status == .running }.count
        for index in tasks.indices where tasks[index].status == .queued {
            guard running < maxConcurrent else { break }
            guard workTasks[tasks[index].id] == nil else { continue }
            running += 1
            start(at: index)
        }
    }

    private func start(at index: Int) {
        let id = tasks[index].id
        let direction = tasks[index].direction
        let bucket = tasks[index].bucket
        let key = tasks[index].key
        let url = tasks[index].localURL
        let destinationBucket = tasks[index].destinationBucket
        let destinationKey = tasks[index].destinationKey
        let moveSource = tasks[index].moveSource
        let taskSize = tasks[index].size
        let taskETag = tasks[index].sourceETag
        let resumeFrom = tasks[index].bytesDone
        let resumeETag = tasks[index].downloadETag
        guard workTasks[id] == nil else { return }
        let generation = (workGeneration[id] ?? 0) + 1
        workGeneration[id] = generation
        if direction == .copy {
            if let provider = credentialProvider,
               let sourceID = tasks[index].accountID,
               let destinationID = tasks[index].destinationAccountID {
                copyCredentials[id] = nil
                let source = provider(sourceID)
                let destination = provider(destinationID)
                if let source, let destination {
                    copyCredentials[id] = CopyCredentials(source: source, destination: destination)
                }
            }
            guard copyCredentials[id] != nil else {
                markFailed(
                    id,
                    message: S3ServiceError.missingCredentials.localizedDescription,
                    generation: generation
                )
                return
            }
        } else if let accountID = tasks[index].accountID, let provider = credentialProvider {
            credentials[id] = provider(accountID)
        }
        let account: Account
        let secret: String
        if direction == .copy, let copy = copyCredentials[id] {
            account = copy.source.0
            secret = copy.source.1
        } else if let credential = credentials[id] {
            account = credential.0
            secret = credential.1
        } else {
            markFailed(
                id,
                message: S3ServiceError.missingCredentials.localizedDescription,
                generation: generation
            )
            return
        }

        if direction == .upload, tasks[index].isRestored {
            let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
            let actualSize = (attributes?[.size] as? NSNumber)?.int64Value
            let actualModified = (attributes?[.modificationDate] as? Date)?.timeIntervalSince1970
            let modifiedChanged = tasks[index].sourceModifiedAt.flatMap { expected in
                actualModified.map { abs($0 - expected) > 0.01 }
            } ?? false
            if attributes == nil || actualSize != tasks[index].size || modifiedChanged {
                markFailed(
                    id,
                    message: "Source file changed before the upload started; re-add it.",
                    generation: generation
                )
                return
            }
        }

        tasks[index].status = .running
        tasks[index].startedAt = Date()
        tasks[index].error = nil
        lastSample[id] = (Date(), 0)
        log("\(direction.rawValue) started: \(key)")
        change()

        workTasks[id] = Task {
            do {
                switch direction {
                case .upload:
                    try await service.upload(
                        account: account, secret: secret, bucket: bucket, key: key, from: url,
                        multipartStore: multipartStore,
                        progress: { bytes in
                            Task { @MainActor in
                                self.updateProgress(id, bytes: bytes, generation: generation)
                            }
                        }
                    )
                case .download:
                    let temporary = S3Service.downloadTemporaryURL(for: url)
                    temporaryRegistry.register(temporary)
                    let result = try await service.download(
                        account: account, secret: secret, bucket: bucket, key: key, to: url,
                        resumeFrom: resumeFrom,
                        expectedETag: resumeETag,
                        onMetadata: { eTag, totalSize in
                            Task { @MainActor in
                                self.updateDownloadMetadata(
                                    id, generation: generation, eTag: eTag, totalSize: totalSize
                                )
                            }
                        },
                        progress: { bytes in
                            Task { @MainActor in
                                self.updateProgress(id, bytes: bytes, generation: generation)
                            }
                        }
                    )
                    self.applyDownloadResult(id, generation: generation, result: result)
                case .copy:
                    guard let copy = copyCredentials[id],
                          let destinationBucket,
                          let destinationKey else {
                        throw S3ServiceError.missingCredentials
                    }
                    let temporary = url
                    let downloadTemporary = S3Service.downloadTemporaryURL(for: temporary)
                    try? FileManager.default.removeItem(at: temporary)
                    try? FileManager.default.removeItem(at: downloadTemporary)
                    defer {
                        try? FileManager.default.removeItem(at: temporary)
                        try? FileManager.default.removeItem(at: downloadTemporary)
                    }

                    let sourceDetails = try await service.objectDetails(
                        account: account, secret: secret, bucket: bucket, key: key
                    )
                    let expectedSize = sourceDetails.contentLength ?? taskSize
                    let initialETag = sourceDetails.eTag ?? taskETag
                    self.updateCopyMetadata(
                        id, generation: generation, size: expectedSize, eTag: initialETag
                    )

                    let result = try await service.download(
                        account: account, secret: secret, bucket: bucket, key: key, to: temporary,
                        progress: { bytes in
                            Task { @MainActor in
                                self.updateCopyProgress(
                                    id, generation: generation, phase: .download, bytes: bytes
                                )
                            }
                        }
                    )
                    if let initial = self.normalizedETag(initialETag),
                       let downloaded = self.normalizedETag(result.eTag),
                       initial != downloaded {
                        throw S3ServiceError.sourceChangedDuringCopy
                    }

                    try Task.checkCancellation()
                    guard self.isCurrent(id, generation: generation) else {
                        throw CancellationError()
                    }
                    try await service.upload(
                        account: copy.destination.0,
                        secret: copy.destination.1,
                        bucket: destinationBucket,
                        key: destinationKey,
                        from: temporary,
                        contentType: sourceDetails.contentType,
                        metadata: sourceDetails.metadata,
                        multipartStore: multipartStore,
                        progress: { bytes in
                            Task { @MainActor in
                                self.updateCopyProgress(
                                    id, generation: generation, phase: .upload, bytes: bytes
                                )
                            }
                        },
                        onUploadID: { uploadID in
                            Task { @MainActor in
                                self.updateCopyUploadID(
                                    id, generation: generation, uploadID: uploadID
                                )
                            }
                        }
                    )
                    let destinationDetails: ObjectDetails
                    do {
                        destinationDetails = try await service.objectDetails(
                            account: copy.destination.0,
                            secret: copy.destination.1,
                            bucket: destinationBucket,
                            key: destinationKey
                        )
                    } catch {
                        throw S3ServiceError.destinationVerificationFailed
                    }
                    guard let destinationSize = destinationDetails.contentLength,
                          destinationSize == result.bytesWritten else {
                        throw S3ServiceError.destinationVerificationFailed
                    }
                    if moveSource {
                        try Task.checkCancellation()
                        guard self.isCurrent(id, generation: generation) else {
                            throw CancellationError()
                        }
                        let current = try await service.objectDetails(
                            account: account, secret: secret, bucket: bucket, key: key
                        )
                        guard current.contentLength == result.bytesWritten else {
                            throw S3ServiceError.sourceChangedDuringCopy
                        }
                        if let initial = self.normalizedETag(initialETag),
                           let currentETag = self.normalizedETag(current.eTag),
                           initial != currentETag {
                            throw S3ServiceError.sourceChangedDuringCopy
                        }
                        try await service.delete(
                            account: account, secret: secret, bucket: bucket, key: key
                        )
                    }
                }
                finish(id, generation: generation)
            } catch is CancellationError {
                handleCancellation(id, generation: generation)
            } catch {
                let taskIndex = self.index(of: id)
                if Task.isCancelled || taskIndex.map({ tasks[$0].status == .paused }) == true {
                    handleCancellation(id, generation: generation)
                } else {
                    markFailed(id, message: S3ErrorPresenter.message(for: error), generation: generation)
                }
            }
        }
    }

    private func updateProgress(_ id: UUID, bytes: Int64, generation: Int) {
        guard workGeneration[id] == generation,
              let index = index(of: id),
              tasks[index].status == .running else { return }
        tasks[index].bytesDone = tasks[index].size > 0 ? min(bytes, tasks[index].size) : bytes
        if tasks[index].direction == .download { schedulePersistence() }

        let now = Date()
        if let sample = lastSample[id] {
            let dt = now.timeIntervalSince(sample.at)
            if dt > 0.2 {
                let instant = Double(bytes - sample.bytes) / dt
                tasks[index].speed = tasks[index].speed == 0 ? instant : (tasks[index].speed * 0.7 + instant * 0.3)
                lastSample[id] = (now, bytes)
            }
        }

        if now.timeIntervalSince(lastEmit) > 0.1 {
            lastEmit = now
            onChange?()
        }
    }

    private enum CopyPhase {
        case download
        case upload
    }

    private func updateCopyMetadata(
        _ id: UUID, generation: Int, size: Int64, eTag: String?
    ) {
        guard workGeneration[id] == generation,
              let index = index(of: id) else { return }
        if size > 0 { tasks[index].size = size }
        if let eTag { tasks[index].sourceETag = eTag }
        schedulePersistence()
    }

    private func updateCopyUploadID(
        _ id: UUID, generation: Int, uploadID: String?
    ) {
        guard workGeneration[id] == generation, let index = index(of: id) else { return }
        tasks[index].destinationUploadID = uploadID
        schedulePersistence()
    }

    private func updateCopyProgress(
        _ id: UUID, generation: Int, phase: CopyPhase, bytes: Int64
    ) {
        guard workGeneration[id] == generation,
              let index = index(of: id),
              tasks[index].status == .running else { return }
        let total = tasks[index].size
        let mapped: Int64
        if total > 0 {
            let half = total / 2
            mapped = phase == .download
                ? min(half, bytes / 2)
                : min(total, half + min(half, bytes / 2))
        } else {
            mapped = bytes
        }
        tasks[index].bytesDone = mapped
        schedulePersistence()

        let now = Date()
        if let sample = lastSample[id] {
            let dt = now.timeIntervalSince(sample.at)
            if dt > 0.2 {
                let instant = Double(mapped - sample.bytes) / dt
                tasks[index].speed = tasks[index].speed == 0
                    ? instant
                    : (tasks[index].speed * 0.7 + instant * 0.3)
                lastSample[id] = (now, mapped)
            }
        }
        if now.timeIntervalSince(lastEmit) > 0.1 {
            lastEmit = now
            onChange?()
        }
    }

    private func updateDownloadMetadata(
        _ id: UUID, generation: Int, eTag: String?, totalSize: Int64?
    ) {
        guard workGeneration[id] == generation,
              let index = index(of: id),
              tasks[index].status == .running else { return }
        if let eTag { tasks[index].downloadETag = eTag }
        if let totalSize, totalSize > 0 { tasks[index].size = totalSize }
        schedulePersistence()
    }

    private func applyDownloadResult(
        _ id: UUID, generation: Int, result: DownloadResult
    ) {
        guard workGeneration[id] == generation, let index = index(of: id) else { return }
        tasks[index].bytesDone = result.bytesWritten
        if let totalSize = result.totalSize, totalSize > 0 { tasks[index].size = totalSize }
        tasks[index].downloadETag = result.eTag ?? tasks[index].downloadETag
        schedulePersistence()
    }

    private func finish(_ id: UUID, generation: Int) {
        guard workGeneration[id] == generation, let index = index(of: id) else { return }
        tasks[index].status = .completed
        tasks[index].bytesDone = tasks[index].size
        tasks[index].speed = 0
        tasks[index].finishedAt = Date()
        log("Completed \(tasks[index].direction.rawValue.lowercased()) \(tasks[index].key)")
        let account = tasks[index].direction == .copy
            ? copyCredentials[id]?.source.0
            : credentials[id]?.0
        let event: String
        switch tasks[index].direction {
        case .upload: event = "object.uploaded"
        case .download: event = "object.downloaded"
        case .copy: event = tasks[index].moveSource ? "object.moved" : "object.copied"
        }
        audit(event, task: tasks[index], account: account, outcome: "success")
        if tasks[index].direction == .download {
            temporaryRegistry.unregister(S3Service.downloadTemporaryURL(for: tasks[index].localURL))
        } else if tasks[index].direction == .copy {
            cleanupCopyTemporary(tasks[index])
        }
        workTasks[id] = nil
        workGeneration[id] = nil
        credentials[id] = nil
        copyCredentials[id] = nil
        lastSample[id] = nil
        change()
        onFinished?()
        pump()
    }

    private func handleCancellation(_ id: UUID, generation: Int) {
        guard workGeneration[id] == generation, let index = index(of: id) else { return }
        if tasks[index].status == .running {
            tasks[index].status = .paused
            tasks[index].speed = 0
        }
        if tasks[index].direction == .copy {
            if let copy = copyCredentials[id] {
                abortCopyMultipart(task: tasks[index], credentials: copy)
            }
            cleanupCopyTemporary(tasks[index])
        }
        if credentialProvider != nil {
            credentials[id] = nil
            copyCredentials[id] = nil
        }
        workTasks[id] = nil
        change()
        pump()
    }

    private func markFailed(_ id: UUID, message: String, generation: Int) {
        guard workGeneration[id] == generation, let index = index(of: id) else { return }
        tasks[index].status = .failed
        tasks[index].error = message
        tasks[index].speed = 0
        tasks[index].finishedAt = Date()
        log("Failed \(tasks[index].key): \(message)")
        let account = tasks[index].direction == .copy
            ? copyCredentials[id]?.source.0
            : credentials[id]?.0
        audit("transfer.failed", task: tasks[index], account: account, outcome: "failure")
        if tasks[index].direction == .copy {
            if let copy = copyCredentials[id] {
                abortCopyMultipart(task: tasks[index], credentials: copy)
            }
            cleanupCopyTemporary(tasks[index])
            copyCredentials[id] = nil
        }
        if credentialProvider != nil { credentials[id] = nil }
        workTasks[id] = nil
        workGeneration[id] = nil
        lastSample[id] = nil
        change()
        pump()
    }

    private func abortCopyMultipart(task: TransferTask, credentials: CopyCredentials) {
        guard let bucket = task.destinationBucket,
              let key = task.destinationKey,
              let uploadID = task.destinationUploadID else { return }
        log("Aborting destination multipart upload \(bucket)/\(key)")
        let service = service
        let store = multipartStore
        Task {
            await service.abortMultipart(
                account: credentials.destination.0,
                secret: credentials.destination.1,
                bucket: bucket,
                key: key,
                uploadID: uploadID,
                store: store
            )
        }
    }

    private func cleanupCopyTemporary(_ task: TransferTask) {
        guard S3Service.isCopyTemporaryURL(task.localURL) else { return }
        let downloadTemporary = S3Service.downloadTemporaryURL(for: task.localURL)
        try? FileManager.default.removeItem(at: task.localURL)
        try? FileManager.default.removeItem(at: downloadTemporary)
        temporaryRegistry.unregister(task.localURL)
        temporaryRegistry.unregister(downloadTemporary)
    }

    private func index(of id: UUID) -> Int? {
        tasks.firstIndex { $0.id == id }
    }

    private func isCurrent(_ id: UUID, generation: Int) -> Bool {
        guard workGeneration[id] == generation,
              let index = index(of: id) else { return false }
        return tasks[index].status == .running
    }

    private func normalizedETag(_ value: String?) -> String? {
        guard var value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else { return nil }
        if value.hasPrefix("W/") { value.removeFirst(2) }
        if value.hasPrefix("\"") { value.removeFirst() }
        if value.hasSuffix("\"") { value.removeLast() }
        return value.isEmpty ? nil : value
    }

    private func change() {
        onChange?()
        schedulePersistence()
    }

    private func clearRuntimeState(for id: UUID) {
        workGeneration[id] = nil
        lastSample[id] = nil
        workTasks[id] = nil
    }

    private func audit(_ event: String, task: TransferTask, account: Account?, outcome: String) {
        let message: String
        switch task.direction {
        case .upload: message = "Upload transfer event"
        case .download: message = "Download transfer event"
        case .copy: message = task.moveSource ? "Move transfer event" : "Copy transfer event"
        }
        var metadata = [
            "bytes": String(task.size),
            "completedBytes": String(task.bytesDone)
        ]
        if let destinationAccountID = task.destinationAccountID {
            metadata["destinationAccountID"] = destinationAccountID.uuidString
        }
        if let destinationBucket = task.destinationBucket {
            metadata["destinationBucket"] = destinationBucket
        }
        if let destinationKey = task.destinationKey {
            metadata["destinationKey"] = destinationKey
        }
        LogStore.shared.audit(
            event: event,
            message: message,
            accountID: account?.id,
            accountName: account?.displayName,
            bucket: task.bucket,
            key: task.key,
            operation: task.direction.rawValue,
            outcome: outcome,
            metadata: metadata
        )
    }

    private func log(_ message: String) {
        onLog?(message)
    }
}
