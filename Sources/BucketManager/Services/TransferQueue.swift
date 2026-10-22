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
        let active = Set(tasks.compactMap { task -> String? in
            guard task.direction == .download,
                  [.queued, .running, .paused, .failed].contains(task.status) else { return nil }
            return S3Service.downloadTemporaryURL(for: task.localURL).path
        })
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
            task.sourceModifiedAt = record.fileModified
            task.isRestored = true
            task.speed = 0
            task.startedAt = nil
            task.finishedAt = nil
            task.error = record.error
            if record.direction == .download {
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
            audit("transfer.paused", task: tasks[index], account: credentials[id]?.0, outcome: "success")
            if credentialProvider != nil { credentials[id] = nil }
        } else if tasks[index].status == .queued {
            tasks[index].status = .paused
            audit("transfer.paused", task: tasks[index], account: credentials[id]?.0, outcome: "success")
            if credentialProvider != nil { credentials[id] = nil }
        }
        change()
    }

    func cancel(id: UUID) {
        guard let index = index(of: id) else { return }
        let wasRunning = tasks[index].status == .running
        let task = tasks[index]
        let credentials = credentials[id]
        tasks[index].status = .canceled
        tasks[index].speed = 0
        tasks[index].finishedAt = Date()
        let work = workTasks[id]
        work?.cancel()
        workTasks[id] = nil
        workGeneration[id] = nil
        lastSample[id] = nil
        self.credentials[id] = nil
        audit("transfer.canceled", task: task, account: credentials?.0, outcome: "success")
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
                downloadETag: task.downloadETag
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
        guard workTasks[id] == nil else { return }
        let generation = (workGeneration[id] ?? 0) + 1
        workGeneration[id] = generation
        if let accountID = tasks[index].accountID, let provider = credentialProvider {
            credentials[id] = provider(accountID)
        }
        guard let (account, secret) = credentials[id] else {
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
                    let resumeFrom = tasks[index].bytesDone
                    let resumeETag = tasks[index].downloadETag
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
        let account = credentials[id]?.0
        audit(
            tasks[index].direction == .upload ? "object.uploaded" : "object.downloaded",
            task: tasks[index],
            account: account,
            outcome: "success"
        )
        if tasks[index].direction == .download {
            temporaryRegistry.unregister(S3Service.downloadTemporaryURL(for: tasks[index].localURL))
        }
        workTasks[id] = nil
        workGeneration[id] = nil
        credentials[id] = nil
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
        if credentialProvider != nil { credentials[id] = nil }
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
        audit("transfer.failed", task: tasks[index], account: credentials[id]?.0, outcome: "failure")
        if credentialProvider != nil { credentials[id] = nil }
        workTasks[id] = nil
        workGeneration[id] = nil
        lastSample[id] = nil
        change()
        pump()
    }

    private func index(of id: UUID) -> Int? {
        tasks.firstIndex { $0.id == id }
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
        LogStore.shared.audit(
            event: event,
            message: task.direction == .upload ? "Upload transfer event" : "Download transfer event",
            accountID: account?.id,
            accountName: account?.displayName,
            bucket: task.bucket,
            key: task.key,
            operation: task.direction.rawValue,
            outcome: outcome,
            metadata: [
                "bytes": String(task.size),
                "completedBytes": String(task.bytesDone)
            ]
        )
    }

    private func log(_ message: String) {
        onLog?(message)
    }
}
