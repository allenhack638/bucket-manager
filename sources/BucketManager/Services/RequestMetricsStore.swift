import Foundation

struct RequestMetric: Codable, Identifiable, Sendable {
    var accountID: UUID
    var accountName: String
    var bucket: String
    var operation: String
    var count: Int64 = 0
    var sessionCount: Int64 = 0
    var failures: Int64 = 0
    var bytes: Int64 = 0
    var totalDurationMs: Double = 0
    var maxDurationMs: Double = 0
    var firstAt: Date
    var lastAt: Date

    var id: String { "\(accountID.uuidString)|\(bucket)|\(operation)" }
    var averageDurationMs: Double { count == 0 ? 0 : totalDurationMs / Double(count) }
}

final class RequestMetricsStore: @unchecked Sendable {
    static let shared = RequestMetricsStore()

    private let queue = DispatchQueue(label: "com.bucketmanager.requestmetrics")
    private let fileURL: URL
    private var metrics: [String: RequestMetric] = [:]
    private var saveWorkItem: DispatchWorkItem?
    private var loaded = false

    static var defaultFileURL: URL {
        #if DEBUG
        if let override = ProcessInfo.processInfo.environment["S3C_METRICS_FILE"],
           !override.isEmpty {
            return URL(fileURLWithPath: override)
        }
        #endif
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support", isDirectory: true)
        return base
            .appendingPathComponent("BucketManager", isDirectory: true)
            .appendingPathComponent("request-metrics.json")
    }

    init(fileURL: URL? = nil) {
        self.fileURL = fileURL ?? Self.defaultFileURL
    }

    func record(
        account: Account,
        bucket: String?,
        operation: String,
        outcome: String,
        durationMs: Double,
        bytes: Int64 = 0
    ) {
        queue.async { [weak self] in
            guard let self else { return }
            self.loadIfNeeded()
            let bucket = bucket ?? ""
            let key = "\(account.id.uuidString)|\(bucket)|\(operation)"
            var metric = self.metrics[key] ?? RequestMetric(
                accountID: account.id,
                accountName: account.displayName,
                bucket: bucket,
                operation: operation,
                firstAt: Date(),
                lastAt: Date()
            )
            metric.accountName = account.displayName
            metric.count += 1
            metric.sessionCount += 1
            if outcome != "success" { metric.failures += 1 }
            metric.bytes += bytes
            metric.totalDurationMs += durationMs
            metric.maxDurationMs = max(metric.maxDurationMs, durationMs)
            metric.lastAt = Date()
            self.metrics[key] = metric
            self.scheduleSave()
        }
    }

    func snapshot() -> [RequestMetric] {
        queue.sync {
            loadIfNeeded()
            return metrics.values.sorted {
                if $0.accountName != $1.accountName {
                    return $0.accountName.localizedStandardCompare($1.accountName) == .orderedAscending
                }
                if $0.bucket != $1.bucket {
                    return $0.bucket.localizedStandardCompare($1.bucket) == .orderedAscending
                }
                return $0.operation < $1.operation
            }
        }
    }

    func clear() {
        queue.sync {
            metrics = [:]
            saveWorkItem?.cancel()
            saveWorkItem = nil
            persist()
        }
    }

    func flush() {
        queue.sync {
            saveWorkItem?.cancel()
            saveWorkItem = nil
            persist()
        }
    }

    private func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        guard let data = try? Data(contentsOf: fileURL),
              var decoded = try? JSONDecoder().decode([RequestMetric].self, from: data) else {
            return
        }
        for index in decoded.indices {
            decoded[index].sessionCount = 0
        }
        metrics = Dictionary(uniqueKeysWithValues: decoded.map { ($0.id, $0) })
    }

    private func scheduleSave() {
        saveWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.loadIfNeeded()
            self.persist()
        }
        saveWorkItem = item
        queue.asyncAfter(deadline: .now() + 1, execute: item)
    }

    private func persist() {
        do {
            let directory = fileURL.deletingLastPathComponent()
            if !FileManager.default.fileExists(atPath: directory.path) {
                try FileManager.default.createDirectory(
                    at: directory,
                    withIntermediateDirectories: true,
                    attributes: [.posixPermissions: 0o700]
                )
            }
            let data = try JSONEncoder().encode(metrics.values.sorted { $0.id < $1.id })
            try data.write(to: fileURL, options: .atomic)
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: fileURL.path
            )
        } catch {
            let message = "Could not save request metrics: \(error.localizedDescription)\n"
            FileHandle.standardError.write(Data(message.utf8))
        }
    }
}
