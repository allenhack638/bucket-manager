import Foundation

enum MultipartOrphanPlanner {
    static func orphans(
        records: [MultipartUploadRecord],
        activeUploads: [TransferTask],
        now: Date = Date(),
        grace: TimeInterval
    ) -> [MultipartUploadRecord] {
        let active = Set(activeUploads.compactMap { task -> String? in
            guard [.queued, .running, .paused, .failed].contains(task.status) else { return nil }
            switch task.direction {
            case .upload:
                guard let accountID = task.accountID else { return nil }
                return "\(accountID.uuidString)|\(task.bucket)|\(task.key)"
            case .copy:
                guard let accountID = task.destinationAccountID,
                      let bucket = task.destinationBucket,
                      let key = task.destinationKey else { return nil }
                return "\(accountID.uuidString)|\(bucket)|\(key)"
            case .download:
                return nil
            }
        })
        let cutoff = now.addingTimeInterval(-grace)
        return records.filter { record in
            let key = "\(record.accountID.uuidString)|\(record.bucket)|\(record.key)"
            return !active.contains(key) && record.updatedAt < cutoff
        }
    }
}
