#if DEBUG
import Foundation

/// Headless S3 signing probe used during development. Reads credentials from
/// the environment so the secret never appears in source or logs.
enum Probe {
    static func run() {
        let env = ProcessInfo.processInfo.environment
        guard let endpoint = env["S3C_ENDPOINT"],
              let region = env["S3C_REGION"],
              let key = env["S3C_ACCESS_KEY"],
              let secret = env["S3C_SECRET"] else {
            print("PROBE_FAIL missing env (S3C_ENDPOINT, S3C_REGION, S3C_ACCESS_KEY, S3C_SECRET)")
            return
        }
        let account = Account(
            displayName: "probe",
            accessKeyID: key,
            kind: .compatible,
            region: region,
            endpoint: endpoint,
            usePathStyle: env["S3C_PATH_STYLE"] == "1"
        )
        let semaphore = DispatchSemaphore(value: 0)
        Task.detached {
            do {
                let buckets = try await S3Service.shared.listBuckets(account: account, secret: secret, useCache: false)
                print("PROBE_OK buckets=\(buckets.count) first=\(buckets.first?.name ?? "-")")
                if let bucket = env["S3C_BUCKET"] {
                    let page = try await S3Service.shared.list(
                        account: account, secret: secret, bucket: bucket, prefix: "", useCache: false
                    )
                    print("PROBE_LIST bucket=\(bucket) items=\(page.items.count) folders=\(page.items.filter { $0.kind == .folder }.count)")
                }
            } catch {
                print("PROBE_FAIL \(error)")
            }
            semaphore.signal()
        }
        semaphore.wait()
    }
}
#endif
