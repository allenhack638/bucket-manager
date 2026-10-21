import Foundation

@MainActor
final class TransferQueue {
    private(set) var tasks: [TransferTask] = []

    var onChange: (() -> Void)?
    var onLog: ((String) -> Void)?
    var onFinished: (() -> Void)?

    private let service = S3Service.shared
    private let maxConcurrent = 4
    private var credentials: [UUID: (Account, String)] = [:]
    private var workTasks: [UUID: Task<Void, Never>] = [:]
    private var lastSample: [UUID: (at: Date, bytes: Int64)] = [:]
    private var lastEmit: Date = .distantPast

    var runningCount: Int { tasks.filter { $0.status == .running }.count }
    var queuedCount: Int { tasks.filter { $0.status == .queued }.count }
    var stoppedCount: Int { tasks.filter { $0.status == .paused }.count }
    var failedCount: Int { tasks.filter { $0.status == .failed }.count }

    var totalBytes: Int64 { tasks.reduce(0) { $0 + $1.size } }
    var doneBytes: Int64 { tasks.reduce(0) { $0 + $1.bytesDone } }
    var aggregateSpeed: Double { tasks.filter { $0.status == .running }.reduce(0) { $0 + $1.speed } }

    // MARK: - Enqueue

    func enqueueUpload(account: Account, secret: String, bucket: String, key: String, url: URL) {
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value ?? 0
        var task = TransferTask(direction: .upload, bucket: bucket, key: key, localURL: url, size: size)
        task.status = .queued
        tasks.append(task)
        credentials[task.id] = (account, secret)
        log("Queued upload \(key) (\(size.byteString))")
        change()
        pump()
    }

    func enqueueDownload(account: Account, secret: String, bucket: String, key: String, size: Int64, to url: URL) {
        var task = TransferTask(direction: .download, bucket: bucket, key: key, localURL: url, size: size)
        task.status = .queued
        tasks.append(task)
        credentials[task.id] = (account, secret)
        log("Queued download \(key) (\(size.byteString))")
        change()
        pump()
    }

    // MARK: - Demo data (snapshot/self-test only)

    func seedDemoTasks() {
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
            workTasks[id] = nil
            log("Stopped \(tasks[index].key)")
        } else if tasks[index].status == .queued {
            tasks[index].status = .paused
        }
        change()
    }

    func cancel(id: UUID) {
        guard let index = index(of: id) else { return }
        let wasRunning = tasks[index].status == .running
        tasks[index].status = .canceled
        tasks[index].speed = 0
        tasks[index].finishedAt = Date()
        workTasks[id]?.cancel()
        workTasks[id] = nil
        if tasks[index].direction == .download { try? FileManager.default.removeItem(at: tasks[index].localURL) }
        credentials[id] = nil
        log("Canceled \(tasks[index].key)")
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
            case .paused, .failed, .canceled:
                tasks[index].status = .queued
                tasks[index].bytesDone = 0
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
        guard let index = index(of: id) else { return }
        tasks[index].status = .queued
        tasks[index].bytesDone = 0
        tasks[index].error = nil
        tasks[index].startedAt = nil
        tasks[index].finishedAt = nil
        change()
        pump()
    }

    func clearFinished() {
        let finished = tasks.filter { $0.status == .completed || $0.status == .canceled }
        for task in finished { credentials[task.id] = nil }
        tasks.removeAll { $0.status == .completed || $0.status == .canceled }
        change()
    }

    // MARK: - Pumping

    private func pump() {
        var running = tasks.filter { $0.status == .running }.count
        for index in tasks.indices where tasks[index].status == .queued {
            guard running < maxConcurrent else { break }
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
        guard let (account, secret) = credentials[id] else {
            markFailed(id, message: S3ServiceError.missingCredentials.localizedDescription)
            return
        }

        tasks[index].status = .running
        tasks[index].startedAt = Date()
        tasks[index].error = nil
        lastSample[id] = (Date(), 0)
        log("\(direction.rawValue) started: \(key)")

        workTasks[id] = Task {
            do {
                switch direction {
                case .upload:
                    try await service.upload(
                        account: account, secret: secret, bucket: bucket, key: key, from: url,
                        progress: { bytes in
                            Task { @MainActor in self.updateProgress(id, bytes: bytes) }
                        }
                    )
                case .download:
                    try await service.download(
                        account: account, secret: secret, bucket: bucket, key: key, to: url,
                        progress: { bytes in
                            Task { @MainActor in self.updateProgress(id, bytes: bytes) }
                        }
                    )
                }
                finish(id)
            } catch is CancellationError {
                handleCancellation(id)
            } catch {
                markFailed(id, message: Self.friendly(error))
            }
        }
    }

    private func updateProgress(_ id: UUID, bytes: Int64) {
        guard let index = index(of: id), tasks[index].status == .running else { return }
        tasks[index].bytesDone = min(bytes, tasks[index].size)

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
            change()
        }
    }

    private func finish(_ id: UUID) {
        guard let index = index(of: id) else { return }
        tasks[index].status = .completed
        tasks[index].bytesDone = tasks[index].size
        tasks[index].speed = 0
        tasks[index].finishedAt = Date()
        log("Completed \(tasks[index].direction.rawValue.lowercased()) \(tasks[index].key)")
        workTasks[id] = nil
        credentials[id] = nil
        lastSample[id] = nil
        change()
        onFinished?()
        pump()
    }

    private func handleCancellation(_ id: UUID) {
        guard let index = index(of: id) else { return }
        if tasks[index].status == .running {
            tasks[index].status = .paused
            tasks[index].speed = 0
        }
        workTasks[id] = nil
        change()
        pump()
    }

    private func markFailed(_ id: UUID, message: String) {
        guard let index = index(of: id) else { return }
        tasks[index].status = .failed
        tasks[index].error = message
        tasks[index].speed = 0
        tasks[index].finishedAt = Date()
        log("Failed \(tasks[index].key): \(message)")
        workTasks[id] = nil
        credentials[id] = nil
        change()
        pump()
    }

    private func index(of id: UUID) -> Int? {
        tasks.firstIndex { $0.id == id }
    }

    private func change() { onChange?() }

    private func log(_ message: String) {
        onLog?(message)
    }

    private static func friendly(_ error: Error) -> String {
        let text = String(describing: error)
        if text.contains("AccessDenied") { return "Access denied by the bucket policy or IAM permissions." }
        if text.contains("NoSuchBucket") { return "The bucket no longer exists." }
        if text.contains("NoSuchKey") { return "The object no longer exists." }
        if text.contains("InvalidAccessKeyId") { return "The access key ID is not valid." }
        if text.contains("SignatureDoesNotMatch") { return "The secret access key is not valid." }
        if text.contains("notConnectedToInternet") || text.contains("networkConnectionLost") {
            return "Network connection lost."
        }
        return text.split(separator: "\n").first.map(String.init) ?? text
    }
}
