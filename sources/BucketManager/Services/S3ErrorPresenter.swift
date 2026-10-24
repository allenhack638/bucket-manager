import Foundation

enum S3ErrorPresenter {
    static func message(for error: Error) -> String {
        if let description = (error as? LocalizedError)?.errorDescription,
           !description.isEmpty {
            return description
        }
        let text = String(describing: error)
        if text.contains("AccessDenied") { return "Access denied. Check the IAM policy for this access key." }
        if text.contains("InvalidAccessKeyId") { return "The access key ID is not valid." }
        if text.contains("SignatureDoesNotMatch") { return "The secret access key is not valid." }
        if text.contains("NoSuchBucket") { return "The bucket does not exist." }
        if text.contains("NoSuchKey") { return "The object does not exist." }
        if text.contains("RULESET_EXHAUSTED") { return "The custom endpoint could not be resolved. Check the endpoint URL." }
        if text.contains("User canceled") || text.contains("-128") {
            return "Keychain access was denied. Click Always Allow when macOS asks, or re-enter the secret via Accounts → Manage accounts."
        }
        if text.contains("notConnectedToInternet") || text.contains("networkConnectionLost") {
            return "Network connection lost."
        }
        return text.split(separator: "\n").first.map(String.init) ?? text
    }
}
