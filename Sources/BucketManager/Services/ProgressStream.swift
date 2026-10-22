import Foundation
import Smithy
import SmithyStreams

/// Wraps a readable file stream and reports consumed bytes for upload progress.
final class ProgressStream: Smithy.Stream, @unchecked Sendable {
    private let inner: FileStream
    private let onProgress: @Sendable (Int64) -> Void

    init(fileHandle: FileHandle, onProgress: @escaping @Sendable (Int64) -> Void) {
        self.inner = FileStream(fileHandle: fileHandle)
        self.onProgress = onProgress
    }

    var position: Data.Index { inner.position }
    var length: Int? { inner.length }
    var isEmpty: Bool { inner.isEmpty }
    var isSeekable: Bool { inner.isSeekable }

    func read(upToCount count: Int) throws -> Data? {
        let data = try inner.read(upToCount: count)
        onProgress(Int64(inner.position))
        return data
    }

    func readAsync(upToCount count: Int) async throws -> Data? {
        let data = try await inner.readAsync(upToCount: count)
        onProgress(Int64(inner.position))
        return data
    }

    func readToEnd() throws -> Data? {
        let data = try inner.readToEnd()
        onProgress(Int64(inner.position))
        return data
    }

    func readToEndAsync() async throws -> Data? {
        let data = try await inner.readToEndAsync()
        onProgress(Int64(inner.position))
        return data
    }

    func seek(toOffset offset: Int) throws {
        try inner.seek(toOffset: offset)
    }

    func write(contentsOf data: Data) throws {}
    func close() { inner.close() }
    func closeWithError(_ error: Error) { inner.close() }
}
