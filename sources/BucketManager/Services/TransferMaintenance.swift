import Foundation

@MainActor
enum TransferMaintenance {
    static func cleanOrphans(
        queue: TransferQueue,
        accounts: AccountStore,
        multipartStore: MultipartUploadStore = .shared,
        now: Date = Date(),
        grace: TimeInterval = 300
    ) async {
        let records = await multipartStore.recordsSnapshot()
        let orphans = MultipartOrphanPlanner.orphans(
            records: records,
            activeUploads: queue.tasks,
            now: now,
            grace: grace
        )
        guard !orphans.isEmpty else { return }

        var aborted = 0
        var deferred = 0
        for record in orphans {
            guard let account = accounts.account(id: record.accountID),
                  let secret = try? accounts.secret(for: account) else {
                deferred += 1
                continue
            }
            let didAbort = await S3Service.shared.abortMultipart(
                account: account,
                secret: secret,
                bucket: record.bucket,
                key: record.key,
                store: multipartStore
            )
            if didAbort {
                aborted += 1
            } else {
                deferred += 1
            }
        }
        LogStore.shared.audit(
            event: "multipart.orphans.cleaned",
            message: "Cleaned stale multipart upload state",
            outcome: aborted > 0 ? "success" : "failure",
            metadata: [
                "aborted": String(aborted),
                "deferred": String(deferred)
            ]
        )
    }
}
