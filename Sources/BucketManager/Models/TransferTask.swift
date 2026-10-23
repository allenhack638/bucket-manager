import Foundation

struct TransferTask: Identifiable, Sendable {
    enum Direction: String, Codable, Sendable {
        case upload = "Upload"
        case download = "Download"
        case copy = "Copy"
    }

    enum Status: String, Codable, Sendable {
        case queued = "Queued"
        case running = "Running"
        case paused = "Stopped"
        case completed = "Completed"
        case failed = "Failed"
        case canceled = "Canceled"
    }

    var id = UUID()
    var direction: Direction
    var bucket: String
    var key: String
    var localURL: URL
    var accountID: UUID? = nil
    var destinationAccountID: UUID? = nil
    var destinationBucket: String? = nil
    var destinationKey: String? = nil
    var moveSource: Bool = false
    var sourceETag: String? = nil
    var sourceModifiedAt: TimeInterval? = nil
    var downloadETag: String? = nil
    var isRestored = false
    var size: Int64
    var bytesDone: Int64 = 0
    var status: Status = .queued
    var speed: Double = 0
    var error: String?
    var startedAt: Date?
    var finishedAt: Date?

    var title: String {
        switch direction {
        case .upload:
            return "Uploading file \(localURL.path) to \(key)"
        case .download:
            return "Downloading \(key) to \(localURL.path)"
        case .copy:
            let destination = [destinationBucket, destinationKey]
                .compactMap { $0 }
                .joined(separator: "/")
            return "\(moveSource ? "Moving" : "Copying") \(bucket)/\(key) to \(destination)"
        }
    }

    var progress: Double {
        guard size > 0 else { return status == .completed ? 1 : 0 }
        return min(1, max(0, Double(bytesDone) / Double(size)))
    }

    var elapsed: TimeInterval {
        guard let startedAt else { return 0 }
        return (finishedAt ?? Date()).timeIntervalSince(startedAt)
    }
}
