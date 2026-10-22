import Foundation

enum LogLevel: Int, Codable, CaseIterable, Sendable, Comparable {
    case trace = 0
    case debug = 10
    case info = 20
    case notice = 25
    case warning = 30
    case error = 40
    case critical = 50

    static func < (lhs: LogLevel, rhs: LogLevel) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    var title: String {
        switch self {
        case .trace: return "Trace"
        case .debug: return "Debug"
        case .info: return "Info"
        case .notice: return "Notice"
        case .warning: return "Warning"
        case .error: return "Error"
        case .critical: return "Critical"
        }
    }
}

enum LogCategory: String, Codable, CaseIterable, Sendable {
    case app
    case account
    case s3Request
    case transfer
    case audit
    case settings
    case ui
    case security

    var title: String {
        switch self {
        case .app: return "App"
        case .account: return "Account"
        case .s3Request: return "S3 Request"
        case .transfer: return "Transfer"
        case .audit: return "Audit"
        case .settings: return "Settings"
        case .ui: return "UI"
        case .security: return "Security"
        }
    }
}

struct LogRecord: Codable, Identifiable, Sendable {
    var id = UUID()
    var timestamp = Date()
    var level: LogLevel
    var category: LogCategory
    var event: String
    var message: String
    var accountID: UUID?
    var accountName: String?
    var bucket: String?
    var key: String?
    var operation: String?
    var outcome: String?
    var durationMs: Double?
    var bytes: Int64?
    var requestID: String?
    var metadata: [String: String] = [:]
}

struct LoggingSettings: Codable, Sendable {
    var diagnosticsEnabled = false
    var minimumLevel: LogLevel = .info
    var enabledCategories: Set<LogCategory> = Set(LogCategory.allCases)
    var auditEnabled = true
    var diagnosticRetentionDays = 14
    var auditRetentionDays = 90
    var maxFileBytes: Int64 = 20 * 1024 * 1024
    var includeObjectKeys = true
}
