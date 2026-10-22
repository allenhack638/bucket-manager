import AppKit

final class BucketNode: NSObject {
    let name: String
    let accountID: UUID?

    init(name: String, accountID: UUID?) {
        self.name = name
        self.accountID = accountID
        super.init()
    }

    var id: String { "bucket:\(accountID?.uuidString ?? "")/\(name)" }

    var icon: NSImage? {
        let image = Theme.Icon.image("shippingbox.fill", style: Theme.Icon.row)
        image?.accessibilityDescription = "Bucket"
        return image
    }

    override func isEqual(_ object: Any?) -> Bool {
        guard let other = object as? BucketNode else { return false }
        return id == other.id
    }

    override var hash: Int { id.hashValue }
}
