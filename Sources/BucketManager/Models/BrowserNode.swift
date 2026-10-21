import AppKit

final class BrowserNode: NSObject {
    enum Kind {
        case account
        case bucket
        case folder
    }

    let kind: Kind
    let title: String
    let accountID: UUID?
    let bucket: String?
    let prefix: String?
    var children: [BrowserNode] = []
    var isLoading = false
    var didLoad = false

    init(kind: Kind, title: String, accountID: UUID? = nil, bucket: String? = nil, prefix: String? = nil) {
        self.kind = kind
        self.title = title
        self.accountID = accountID
        self.bucket = bucket
        self.prefix = prefix
        super.init()
    }

    var id: String {
        switch kind {
        case .account: return "account:\(accountID?.uuidString ?? title)"
        case .bucket: return "bucket:\(accountID?.uuidString ?? "")/\(bucket ?? title)"
        case .folder: return "folder:\(accountID?.uuidString ?? "")/\(bucket ?? "")/\(prefix ?? title)"
        }
    }

    var icon: NSImage? {
        switch kind {
        case .account:
            return Theme.Icon.image("externaldrive.connected.to.line.below", style: Theme.Icon.row)
                ?? Theme.Icon.image("cloud", style: Theme.Icon.row)
        case .bucket:
            let img = Theme.Icon.image("shippingbox.fill", style: Theme.Icon.row)
            img?.accessibilityDescription = "Bucket"
            return img
        case .folder:
            let img = Theme.Icon.image("folder.fill", style: Theme.Icon.row)
            img?.accessibilityDescription = "Folder"
            return img
        }
    }

    override func isEqual(_ object: Any?) -> Bool {
        guard let other = object as? BrowserNode else { return false }
        return id == other.id
    }

    override var hash: Int { id.hashValue }
}
