import Foundation

@MainActor
final class FolderStatsCoordinator {
    let cache: FolderStatsCache
    let scanner: FolderStatsScanner
    private let policy: FolderStatsPolicy
    private let now: () -> Date

    var onSnapshots: (([FolderStatsSnapshot]) -> Void)?

    private var snapshots: [FolderStatsKey: FolderStatsSnapshot] = [:]
    private var tasks: [String: (task: Task<Void, Never>, token: UUID, keys: Set<FolderStatsKey>)] = [:]
    private var failureUntil: [FolderStatsKey: Date] = [:]
    private var activeKeys: Set<FolderStatsKey> = []

    init(
        cache: FolderStatsCache,
        scanner: FolderStatsScanner,
        policy: FolderStatsPolicy = FolderStatsPolicy(),
        now: @escaping () -> Date = Date.init
    ) {
        self.cache = cache
        self.scanner = scanner
        self.policy = policy
        self.now = now
    }

    func snapshot(for key: FolderStatsKey) -> FolderStatsSnapshot? {
        snapshots[key]
    }

    func record(for key: FolderStatsKey) -> FolderStatsRecord? {
        cache.record(for: key)
    }

    func update(keys: [FolderStatsKey], account: Account, secret: String) {
        activeKeys = Set(keys)
        let currentTime = now()

        var scanKeys: [FolderStatsKey] = []
        for key in activeKeys {
            let record = cache.record(for: key)
            if let failedAt = failureUntil[key], failedAt > currentTime {
                snapshots[key] = FolderStatsSnapshot(
                    key: key,
                    record: record,
                    state: .failed("Recent refresh failed")
                )
                continue
            }

            if let record {
                let age = currentTime.timeIntervalSince(record.computedAt)
                if age <= policy.freshTTL {
                    snapshots[key] = FolderStatsSnapshot(
                        key: key,
                        record: record,
                        state: record.partial ? .partial : .ready
                    )
                    continue
                }
                snapshots[key] = FolderStatsSnapshot(
                    key: key,
                    record: record,
                    state: .refreshing
                )
                scanKeys.append(key)
            } else {
                snapshots[key] = FolderStatsSnapshot(key: key, record: nil, state: .loading)
                scanKeys.append(key)
            }
        }

        // Drop snapshots for rows that are no longer visible.
        snapshots = snapshots.filter { activeKeys.contains($0.key) }

        let groups = FolderStatsScanner.groups(for: scanKeys)
        let neededTargets = Set(groups.map(\.targetID))
        for (targetID, entry) in tasks where !neededTargets.contains(targetID) {
            entry.task.cancel()
            tasks[targetID] = nil
        }
        for group in groups where tasks[group.targetID] == nil {
            start(group: group, account: account, secret: secret)
        }

        publish(activeKeys)
    }

    func flush() {
        cache.flush()
    }

    func needsScan(for keys: [FolderStatsKey]) -> Bool {
        let currentTime = now()
        return keys.contains { key in
            if let failedAt = failureUntil[key], failedAt > currentTime { return false }
            guard let record = cache.record(for: key) else { return true }
            return currentTime.timeIntervalSince(record.computedAt) > policy.freshTTL
        }
    }

    func invalidateAccount(accountID: UUID) {
        cache.invalidateAccount(accountID: accountID)
        for (targetID, entry) in tasks where entry.keys.contains(where: { $0.accountID == accountID }) {
            entry.task.cancel()
            tasks[targetID] = nil
        }
        let affected = snapshots.keys.filter { $0.accountID == accountID }
        for key in affected { snapshots[key] = nil }
        failureUntil = failureUntil.filter { $0.key.accountID != accountID }
        publish(Set(affected))
    }

    func invalidateBucket(accountID: UUID, bucket: String) {
        cache.invalidateBucket(accountID: accountID, bucket: bucket)
        for (targetID, entry) in tasks
        where entry.keys.contains(where: { $0.accountID == accountID && $0.bucket == bucket }) {
            entry.task.cancel()
            tasks[targetID] = nil
        }
        let affected = snapshots.keys.filter { $0.accountID == accountID && $0.bucket == bucket }
        for key in affected { snapshots[key] = nil }
        failureUntil = failureUntil.filter { $0.key.accountID != accountID || $0.key.bucket != bucket }
        publish(Set(affected))
    }

    func cancelAll() {
        for entry in tasks.values { entry.task.cancel() }
        tasks.removeAll()
        activeKeys.removeAll()
        failureUntil.removeAll()
        snapshots.removeAll()
    }

    func invalidate(accountID: UUID, bucket: String, prefix: String) {
        cache.invalidate(accountID: accountID, bucket: bucket, prefix: prefix)

        for (targetID, entry) in tasks {
            if entry.keys.contains(where: { $0.accountID == accountID && $0.bucket == bucket }) {
                entry.task.cancel()
                tasks[targetID] = nil
            }
        }

        guard !prefix.isEmpty else { return }
        let affected = snapshots.keys.filter {
            $0.accountID == accountID && $0.bucket == bucket
                && prefix.hasPrefix($0.prefix)
        }
        for key in affected {
            snapshots[key] = nil
            failureUntil[key] = nil
        }
        publish(Set(affected))
    }

    /// Snapshot-mode seeding: records are cache hits and cause no network call.
    func seed(records: [FolderStatsRecord], persist: Bool = false) {
        cache.upsert(records, persist: persist)
    }

    private func start(group: FolderStatsScanGroup, account: Account, secret: String) {
        let token = UUID()
        let task = Task { [weak self] in
            do {
                let records = try await self?.scanner.scan(
                    group: group,
                    account: account,
                    secret: secret
                ) ?? []
                self?.complete(group: group, token: token, records: records)
            } catch is CancellationError {
                self?.cancelled(group: group, token: token)
            } catch {
                self?.failed(group: group, token: token, error: error)
            }
        }
        tasks[group.targetID] = (task, token, group.keys)
    }

    private func complete(group: FolderStatsScanGroup, token: UUID, records: [FolderStatsRecord]) {
        guard let entry = tasks[group.targetID], entry.token == token else { return }
        tasks[group.targetID] = nil
        cache.upsert(records)
        let nowDate = now()

        var changed = Set<FolderStatsKey>()
        for key in group.keys where activeKeys.contains(key) {
            let record = cache.record(for: key)
            snapshots[key] = FolderStatsSnapshot(
                key: key,
                record: record,
                state: (record?.partial == true) ? .partial : .ready
            )
            failureUntil[key] = nil
            changed.insert(key)
        }

        // A parent scan can also cover keys that became visible while it ran.
        for key in activeKeys where changed.contains(key) == false {
            guard let record = cache.record(for: key),
                  record.computedAt >= nowDate.addingTimeInterval(-1) else { continue }
            snapshots[key] = FolderStatsSnapshot(
                key: key,
                record: record,
                state: record.partial ? .partial : .ready
            )
            changed.insert(key)
        }

        publish(changed.isEmpty ? Set(group.keys) : changed)
    }

    private func failed(group: FolderStatsScanGroup, token: UUID, error: Error) {
        guard let entry = tasks[group.targetID], entry.token == token else { return }
        tasks[group.targetID] = nil
        let retryAt = now().addingTimeInterval(policy.failureBackoff)
        var changed = Set<FolderStatsKey>()
        for key in group.keys where activeKeys.contains(key) {
            failureUntil[key] = retryAt
            snapshots[key] = FolderStatsSnapshot(
                key: key,
                record: cache.record(for: key),
                state: .failed(BrowserModel.friendly(error))
            )
            changed.insert(key)
        }
        publish(changed)
    }

    private func cancelled(group: FolderStatsScanGroup, token: UUID) {
        guard let entry = tasks[group.targetID], entry.token == token else { return }
        tasks[group.targetID] = nil
        var changed = Set<FolderStatsKey>()
        for key in group.keys where activeKeys.contains(key) {
            let record = cache.record(for: key)
            snapshots[key] = FolderStatsSnapshot(
                key: key,
                record: record,
                state: record?.partial == true ? .partial : (record == nil ? .idle : .ready)
            )
            changed.insert(key)
        }
        publish(changed)
    }

    private func publish(_ keys: Set<FolderStatsKey>) {
        guard !keys.isEmpty else { return }
        let values = keys.compactMap { snapshots[$0] }
        guard !values.isEmpty else { return }
        onSnapshots?(values)
    }
}
