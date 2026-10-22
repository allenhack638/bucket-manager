import Foundation

final class LogStore: @unchecked Sendable {
    static let shared = LogStore()

    private let queue = DispatchQueue(label: "com.bucketmanager.logstore")
    private let directoryURL: URL
    private let defaults: UserDefaults
    private let settingsKey = "BucketManagerLoggingSettings"
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private var settings: LoggingSettings
    private var lastPrune = Date.distantPast

    static var defaultDirectoryURL: URL {
        #if DEBUG
        if let override = ProcessInfo.processInfo.environment["S3C_LOG_DIR"],
           !override.isEmpty {
            return URL(fileURLWithPath: override)
        }
        #endif
        return FileManager.default
            .urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs/BucketManager", isDirectory: true)
    }

    init(directoryURL: URL? = nil, defaults: UserDefaults? = nil) {
        self.directoryURL = directoryURL ?? Self.defaultDirectoryURL
        if let defaults {
            self.defaults = defaults
        } else {
            #if DEBUG
            if let suite = ProcessInfo.processInfo.environment["S3C_LOG_SETTINGS_SUITE"],
               let testDefaults = UserDefaults(suiteName: suite) {
                self.defaults = testDefaults
            } else {
                self.defaults = .standard
            }
            #else
            self.defaults = .standard
            #endif
        }
        if let data = self.defaults.data(forKey: settingsKey),
           let decoded = try? JSONDecoder().decode(LoggingSettings.self, from: data) {
            settings = decoded
        } else {
            settings = LoggingSettings()
        }
        encoder.dateEncodingStrategy = .iso8601
        decoder.dateDecodingStrategy = .iso8601
        queue.async { [weak self] in
            self?.prepareDirectory()
            self?.pruneIfNeeded(force: true)
        }
    }

    func currentSettings() -> LoggingSettings {
        queue.sync { settings }
    }

    func updateSettings(_ newSettings: LoggingSettings) {
        queue.async { [weak self] in
            guard let self else { return }
            let old = self.settings
            self.settings = newSettings
            if let data = try? JSONEncoder().encode(newSettings) {
                self.defaults.set(data, forKey: self.settingsKey)
            }
            self.prepareDirectory()
            self.pruneIfNeeded(force: true)
            if old.auditEnabled || newSettings.auditEnabled {
                self.appendRecord(LogRecord(
                    level: .notice,
                    category: .audit,
                    event: "settings.logging.changed",
                    message: "Logging settings changed",
                    outcome: "success",
                    metadata: [
                        "diagnosticsEnabled": String(newSettings.diagnosticsEnabled),
                        "minimumLevel": newSettings.minimumLevel.title,
                        "diagnosticRetentionDays": String(newSettings.diagnosticRetentionDays),
                        "auditRetentionDays": String(newSettings.auditRetentionDays),
                        "includeObjectKeys": String(newSettings.includeObjectKeys),
                        "includeLocalPaths": String(newSettings.includeLocalPaths)
                    ]
                ))
            }
        }
    }

    func log(
        _ level: LogLevel,
        category: LogCategory,
        event: String,
        message: String,
        accountID: UUID? = nil,
        accountName: String? = nil,
        bucket: String? = nil,
        key: String? = nil,
        operation: String? = nil,
        outcome: String? = nil,
        durationMs: Double? = nil,
        bytes: Int64? = nil,
        requestID: String? = nil,
        metadata: [String: String] = [:]
    ) {
        queue.async { [weak self] in
            guard let self else { return }
            guard self.settings.diagnosticsEnabled,
                  level >= self.settings.minimumLevel,
                  self.settings.enabledCategories.contains(category) else { return }
            self.appendRecord(LogRecord(
                level: level,
                category: category,
                event: event,
                message: message,
                accountID: accountID,
                accountName: accountName,
                bucket: bucket,
                key: key,
                operation: operation,
                outcome: outcome,
                durationMs: durationMs,
                bytes: bytes,
                requestID: requestID,
                metadata: metadata
            ))
        }
    }

    func audit(
        event: String,
        message: String,
        accountID: UUID? = nil,
        accountName: String? = nil,
        bucket: String? = nil,
        key: String? = nil,
        operation: String? = nil,
        outcome: String = "success",
        metadata: [String: String] = [:]
    ) {
        queue.async { [weak self] in
            guard let self, self.settings.auditEnabled else { return }
            self.appendRecord(LogRecord(
                level: .notice,
                category: .audit,
                event: event,
                message: message,
                accountID: accountID,
                accountName: accountName,
                bucket: bucket,
                key: key,
                operation: operation,
                outcome: outcome,
                metadata: metadata
            ))
        }
    }

    func recent(limit: Int = 5_000) -> [LogRecord] {
        queue.sync {
            pruneIfNeeded(force: false)
            let files = logFiles().sorted {
                let left = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let right = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return left > right
            }
            var records: [LogRecord] = []
            for file in files {
                guard let data = try? Data(contentsOf: file) else { continue }
                for line in data.split(separator: 0x0A) {
                    guard let record = try? decoder.decode(LogRecord.self, from: Data(line)) else { continue }
                    records.append(record)
                }
                if records.count >= limit * 3 { break }
            }
            return Array(records.sorted { $0.timestamp > $1.timestamp }.prefix(limit))
        }
    }

    func clearDiagnostics() {
        queue.async { [weak self] in
            guard let self else { return }
            for file in self.logFiles() where file.lastPathComponent.hasPrefix("diagnostic-") {
                try? FileManager.default.removeItem(at: file)
            }
            if self.settings.auditEnabled {
                self.appendRecord(LogRecord(
                    level: .notice,
                    category: .audit,
                    event: "logs.cleared",
                    message: "Diagnostic logs cleared",
                    outcome: "success"
                ))
            }
        }
    }

    func flush() {
        queue.sync {}
    }

    func directory() -> URL {
        queue.sync { directoryURL }
    }

    private func prepareDirectory() {
        if !FileManager.default.fileExists(atPath: directoryURL.path) {
            try? FileManager.default.createDirectory(
                at: directoryURL,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        }
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: directoryURL.path
        )
    }

    private func appendRecord(_ record: LogRecord) {
        guard record.category == .audit ? settings.auditEnabled : settings.diagnosticsEnabled else {
            return
        }
        let sanitized = LogRedactor.record(record, settings: settings)
        guard let data = try? encoder.encode(sanitized) else { return }
        prepareDirectory()
        let fileURL = fileURL(for: sanitized)
        rotateIfNeeded(fileURL)
        if !FileManager.default.fileExists(atPath: fileURL.path) {
            FileManager.default.createFile(
                atPath: fileURL.path,
                contents: nil,
                attributes: [.posixPermissions: 0o600]
            )
        }
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: fileURL.path
        )
        guard let handle = try? FileHandle(forWritingTo: fileURL) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: data + Data([0x0A]))
        pruneIfNeeded(force: false)
    }

    private func fileURL(for record: LogRecord) -> URL {
        let prefix = record.category == .audit ? "audit" : "diagnostic"
        let day = String(record.timestamp.formatted(.iso8601).prefix(10))
        return directoryURL.appendingPathComponent("\(prefix)-\(day).jsonl")
    }

    private func rotateIfNeeded(_ fileURL: URL) {
        let attributes = try? FileManager.default.attributesOfItem(atPath: fileURL.path)
        let size = (attributes?[.size] as? NSNumber)?.int64Value ?? 0
        guard size >= settings.maxFileBytes else { return }
        let backup = fileURL.appendingPathExtension("1")
        try? FileManager.default.removeItem(at: backup)
        try? FileManager.default.moveItem(at: fileURL, to: backup)
    }

    private func logFiles() -> [URL] {
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        return contents.filter {
            let name = $0.lastPathComponent
            return name.hasPrefix("diagnostic-") || name.hasPrefix("audit-")
        }
    }

    private func pruneIfNeeded(force: Bool) {
        let now = Date()
        guard force || now.timeIntervalSince(lastPrune) > 3_600 else { return }
        lastPrune = now
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        for file in logFiles() {
            let name = file.lastPathComponent
            let isAudit = name.hasPrefix("audit-")
            let dayText = String(name.dropFirst(isAudit ? 6 : 11).prefix(10))
            guard let day = formatter.date(from: dayText) else { continue }
            let retention = isAudit ? settings.auditRetentionDays : settings.diagnosticRetentionDays
            if day < Calendar.current.date(byAdding: .day, value: -retention, to: now) ?? .distantPast {
                try? FileManager.default.removeItem(at: file)
            }
        }
    }
}
