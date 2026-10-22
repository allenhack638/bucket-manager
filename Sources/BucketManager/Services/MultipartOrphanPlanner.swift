import Foundation

enum MultipartOrphanPlanner {
    static func orphans(
        records: [MultipartUploadRecord],
        activeUploads: [TransferTask],
        now: Date = Date(),
        grace: TimeInterval
    ) -> [MultipartUploadRecord] {
        let active = Set(activeUploads.compactMap { task -> String? in
            guard task.direction == .upload,
                  [.queued, .running, .paused, .failed].contains(task.status),
                  let accountID = task.accountID else { return nil }
            return "\(accountID.uuidString)|\(task.bucket)|\(task.key)"
        })
        let cutoff = now.addingTimeInterval(-grace)
        return records.filter { record in
            let key = "\(record.accountID.uuidString)|\(record.bucket)|\(record.key)"
            return !active.contains(key) && record.updatedAt < cutoff
        }
    }
}
