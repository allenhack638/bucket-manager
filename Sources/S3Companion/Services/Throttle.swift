import Foundation

/// A simple async concurrency limiter so bulk operations never issue more than
/// `limit` requests at once against the remote S3 endpoint.
actor Throttle {
    private let limit: Int
    private var active = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(limit: Int) { self.limit = max(1, limit) }

    func run<T: Sendable>(_ work: @Sendable () async throws -> T) async rethrows -> T {
        await acquire()
        defer { release() }
        return try await work()
    }

    private func acquire() async {
        if active < limit {
            active += 1
            return
        }
        await withCheckedContinuation { waiters.append($0) }
        active += 1
    }

    private func release() {
        active -= 1
        if !waiters.isEmpty {
            let w = waiters.removeFirst()
            w.resume()
        }
    }
}
