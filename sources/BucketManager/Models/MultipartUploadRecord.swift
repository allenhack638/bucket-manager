import Foundation

struct MultipartPart: Codable, Sendable, Equatable {
    let number: Int
    let eTag: String
}

struct MultipartUploadRecord: Codable, Sendable {
    let accountID: UUID
    let bucket: String
    let key: String
    let uploadID: String
    let fileSize: Int64
    let fileModified: TimeInterval?
    let partSize: Int
    var parts: [MultipartPart]
    let createdAt: Date
    var updatedAt: Date

    func matches(fileSize: Int64, fileModified: TimeInterval?, partSize: Int) -> Bool {
        self.fileSize == fileSize
            && self.partSize == partSize
            && abs((self.fileModified ?? 0) - (fileModified ?? 0)) < 0.01
    }

    func bytesCompleted(totalSize: Int64) -> Int64 {
        parts.reduce(0) { total, part in
            total + partLength(number: part.number, totalSize: totalSize)
        }
    }

    func partLength(number: Int, totalSize: Int64) -> Int64 {
        let offset = Int64(number - 1) * Int64(partSize)
        return min(Int64(partSize), max(0, totalSize - offset))
    }
}
