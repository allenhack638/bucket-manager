#if DEBUG
import Foundation

/// Hidden diagnostic: reads the saved account, asks for the secret twice to
/// prove the per-launch cache, then lists buckets and one bucket root. No writes.
enum StartupVerify {
    static func run() {
        Task { @MainActor in
            let store = AccountStore()
            guard let account = store.accounts.first else {
                print("VERIFY no saved accounts")
                exit(1)
            }
            do {
                _ = try store.secret(for: account)
                _ = try store.secret(for: account)
                let secret = try store.secret(for: account)
                let buckets = try await S3Service.shared.listBuckets(
                    account: account, secret: secret, useCache: false
                )
                print("VERIFY account=\"\(account.displayName)\" buckets=\(buckets.count)")
                if let bucket = buckets.first {
                    do {
                        let page = try await S3Service.shared.list(
                            account: account, secret: secret,
                            bucket: bucket.name, prefix: "", useCache: false
                        )
                        let folders = page.items.filter { $0.kind == .folder }.count
                        print("VERIFY listing bucket=\(bucket.name) items=\(page.items.count) folders=\(folders)")
                    } catch {
                        print("VERIFY listing skipped bucket=\(bucket.name): \(String(describing: error))")
                    }
                }
                exit(0)
            } catch {
                print("VERIFY failed: \(String(describing: error))")
                exit(1)
            }
        }
        RunLoop.main.run()
    }
}
#endif
