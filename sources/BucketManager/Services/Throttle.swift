import Foundation

/// A simple async concurrency limiter so bulk operations never issue more than
/// `limit` requests at once against the remote S3 endpoint.
actor Throttle {
    private let limit: Int
    private var active = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(limit: Int) { self.limit = max(1, limit) }

    func run<T: Sendable>(_ work: @Sendable () async throws -> T) async throws -> T {
        await acquire()
        defer { release() }
        try Task.checkCancellation()
        return try await work()
    }

    private func acquire() async {
        if active < limit {
            active += 1
            return
        }
        // The releasing side hands its existing slot to this waiter, so do not
        // increment here or the limiter can exceed its limit under contention.
        await withCheckedContinuation { waiters.append($0) }
    }

    private func release() {
        if !waiters.isEmpty {
            waiters.removeFirst().resume()
        } else {
            active -= 1
        }
    }
}
