import Foundation

/// Spaces request starts instead of only limiting how many run at once. Used
/// for folder-size scans so a large prefix cannot make the endpoint look busy.
actor RateLimiter {
    private let interval: TimeInterval
    private var next = Date.distantPast

    init(requestsPerSecond: Double) {
        interval = 1.0 / max(1.0, requestsPerSecond)
    }

    func acquire() async throws {
        let now = Date()
        let start = max(now, next)
        next = start.addingTimeInterval(interval)
        let delay = start.timeIntervalSince(now)
        if delay > 0 {
            try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
        }
    }
}
