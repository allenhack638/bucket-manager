import Foundation
import AWSS3
import AWSSDKIdentity
import SmithyIdentity

/// Non-GUI diagnostic for S3 endpoint resolution. Uses throwaway credentials, so
/// a successful resolution fails later with an auth/network error — what matters
/// is whether we even get past endpoint resolution (no RULESET_EXHAUSTED).
enum SelfTest {
    static func run() {
        let args = CommandLine.arguments
        let endpoint = args.count > 2 ? args[2] : ""
        let region = args.count > 3 ? args[3] : "us-east-1"

        let sem = DispatchSemaphore(value: 0)
        Task {
            await probe(label: "AWS, region=\(region)", region: region, endpoint: nil, pathStyle: false)
            if !endpoint.isEmpty {
                // Direct SDK (no normalization) — shows the raw failure.
                await probe(label: "custom endpoint=\(endpoint) [raw SDK]", region: region, endpoint: endpoint, pathStyle: true)
                // Through S3Service (with normalization) — shows the fix.
                await probeViaService(endpoint: endpoint, region: region)
            }
            sem.signal()
        }
        sem.wait()
    }

    private static func probeViaService(endpoint: String, region: String) async {
        print("── custom endpoint=\(endpoint) [via S3Service, normalized] ──")
        let account = Account(displayName: "test", accessKeyID: "EXAMPLE_ACCESS_KEY",
                              region: region, endpoint: endpoint, usePathStyle: true)
        do {
            _ = try await S3Service.shared.listBuckets(account: account, secret: UUID().uuidString + UUID().uuidString)
            print("   OK (unexpected with dummy creds)")
        } catch {
            let s = String(describing: error)
            if s.contains("RULESET_EXHAUSTED") { print("   ✗ STILL ruleset exhausted") }
            else { print("   ✓ endpoint resolved; failed later as expected:") }
            print("     \(s.prefix(160))")
        }
    }

    private static func probe(label: String, region: String, endpoint: String?, pathStyle: Bool) async {
        print("── \(label) ──")
        do {
            let creds = AWSCredentialIdentity(accessKey: "EXAMPLE_ACCESS_KEY", secret: UUID().uuidString + UUID().uuidString)
            let resolver = StaticAWSCredentialIdentityResolver(creds)
            var config = try await S3Client.S3ClientConfig(
                awsCredentialIdentityResolver: resolver,
                region: region,
                endpoint: endpoint
            )
            if pathStyle { config.forcePathStyle = true }
            let client = S3Client(config: config)
            _ = try await client.listBuckets(input: ListBucketsInput())
            print("   OK (unexpected with dummy creds)")
        } catch {
            let s = String(describing: error)
            if s.contains("RULESET_EXHAUSTED") {
                print("   ✗ ENDPOINT RESOLUTION FAILED (ruleset exhausted)")
            } else {
                print("   ✓ endpoint resolved; failed later as expected:")
            }
            print("     \(s.prefix(200))")
        }
    }
}
