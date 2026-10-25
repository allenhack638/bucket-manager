import AppKit
import Foundation
import UniformTypeIdentifiers

struct S3Item: Identifiable, Hashable, Sendable {
    enum Kind: Sendable { case folder, object }

    var id: String { key }
    var key: String
    var kind: Kind
    var size: Int64?
    var lastModified: Date?
    var storageClass: String?
    var eTag: String?
    var contentType: String?
    var metadata: [String: String] = [:]
    /// The latest version is a delete marker (or, for folders, every key below
    /// is). Only listed when the browser shows deleted objects.
    var isDeleted = false

    var displayName: String {
        if kind == .folder {
            var k = key
            if k.hasSuffix("/") { k.removeLast() }
            return String(k.split(separator: "/").last ?? Substring(k))
        }
        return String(key.split(separator: "/").last ?? Substring(key))
    }

    /// S3-compatible providers (Linode, MinIO, …) may return a zero-byte
    /// `name/` folder marker in `Contents` instead of `CommonPrefixes`.
    /// A trailing slash is the only reliable signal that it is a folder.
    static func listed(
        key: String,
        size: Int64?,
        lastModified: Date?,
        storageClass: String?,
        eTag: String?
    ) -> S3Item {
        let isFolder = key.hasSuffix("/")
        return S3Item(
            key: key,
            kind: isFolder ? .folder : .object,
            size: isFolder ? nil : size,
            lastModified: lastModified,
            storageClass: isFolder ? nil : storageClass,
            eTag: isFolder ? nil : eTag
        )
    }

    var fileExtension: String {
        (displayName as NSString).pathExtension.lowercased()
    }

    var typeDescription: String {
        if kind == .folder { return "Folder" }
        switch fileExtension {
        case "png": return "PNG File"
        case "jpg", "jpeg": return "JPG File"
        case "gif": return "GIF File"
        case "bmp": return "BMP File"
        case "webp": return "WEBP File"
        case "svg": return "SVG File"
        case "pdf": return "PDF File"
        case "zip", "gz", "tar", "7z", "rar": return "ZIP File"
        case "txt": return "TXT File"
        case "csv": return "CSV File"
        case "json": return "JSON File"
        case "xml": return "XML File"
        case "html", "htm": return "HTML Document"
        case "mp4", "mov": return "MP4 File"
        case "mp3", "wav": return "Audio File"
        case "xlsx", "xls": return "Microsoft Excel Worksheet"
        case "docx", "doc": return "Microsoft Word Document"
        case "pptx", "ppt": return "Microsoft PowerPoint"
        case "js": return "JavaScript File"
        case "css": return "CSS File"
        case "md": return "Markdown File"
        case "exe": return "Application"
        default: break
        }
        if let contentType, !contentType.isEmpty { return contentType }
        if let ut = UTType(filenameExtension: fileExtension),
           let description = ut.localizedDescription, !description.isEmpty {
            return description
        }
        return fileExtension.isEmpty ? "File" : "\(fileExtension.uppercased()) File"
    }

    var typeSortKey: String { kind == .folder ? "0folder" : typeDescription.lowercased() }

    @MainActor var icon: NSImage? {
        if kind == .folder {
            let img = Theme.Icon.image("folder.fill", style: Theme.Icon.row)
            img?.accessibilityDescription = "Folder"
            return img
        }
        let symbol: String
        switch fileExtension {
        case "png", "jpg", "jpeg", "gif", "bmp", "webp", "svg", "tiff", "heic": symbol = "photo"
        case "pdf": symbol = "doc.richtext"
        case "zip", "gz", "tar", "7z", "rar": symbol = "archivebox"
        case "txt", "md", "log": symbol = "doc.text"
        case "csv", "xlsx", "xls": symbol = "tablecells"
        case "json", "xml", "js", "css", "html", "htm": symbol = "chevron.left.forwardslash.chevron.right"
        case "mp4", "mov", "avi", "mkv": symbol = "film"
        case "mp3", "wav", "flac", "aac": symbol = "music.note"
        case "exe", "app", "dmg": symbol = "app"
        default: symbol = "doc"
        }
        return Theme.Icon.image(symbol, style: Theme.Icon.row)
    }

    @MainActor var iconTint: NSColor? {
        if kind == .folder { return NSColor(hex: 0xE0A800) }
        switch fileExtension {
        case "png", "jpg", "jpeg", "gif", "bmp", "webp", "svg", "tiff", "heic": return NSColor(hex: 0x0078D4)
        case "pdf": return NSColor(hex: 0xC42B1C)
        case "zip", "gz", "tar", "7z", "rar": return NSColor(hex: 0x8A6D3B)
        case "txt", "md", "log": return NSColor(hex: 0x605E5C)
        case "csv", "xlsx", "xls": return NSColor(hex: 0x0F7B0F)
        case "json", "xml", "js", "css", "html", "htm": return NSColor(hex: 0x8764B8)
        case "mp4", "mov", "avi", "mkv", "mp3", "wav", "flac", "aac": return NSColor(hex: 0x8764B8)
        default: return NSColor(hex: 0x605E5C)
        }
    }
}

struct S3Bucket: Identifiable, Hashable, Sendable {
    var id: String { name }
    var name: String
    var creationDate: Date?
}

struct ObjectVersion: Identifiable, Hashable, Sendable {
    var id: String { versionID + (isDeleteMarker ? "-dm" : "") }
    var versionID: String
    var isLatest: Bool
    var isDeleteMarker: Bool
    var size: Int64?
    var lastModified: Date?
    var eTag: String?
    var storageClass: String?
}

struct ObjectDetails: Sendable {
    var contentType: String?
    var contentLength: Int64?
    var eTag: String?
    var lastModified: Date?
    var storageClass: String?
    var versionID: String?
    var metadata: [String: String] = [:]
    var cacheControl: String?
    var contentDisposition: String?
    var contentEncoding: String?
    var contentLanguage: String?
    var serverSideEncryption: String?
    var expires: String?
    var acceptRanges: String?
    var tags: [String: String] = [:]
}
