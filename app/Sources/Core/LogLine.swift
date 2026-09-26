import Foundation

public enum LogCategory: String, CaseIterable, Sendable {
    case app = "APP", vm = "VM", qemu = "QEMU", boot = "BOOT", display = "DISPLAY"
    case input = "INPUT", jit = "JIT", network = "NETWORK", guest = "GUEST"
    case ipa = "IPA", storage = "STORAGE"
}

public enum LogLevel: String, Comparable, CaseIterable, Sendable {
    case debug = "DEBUG", info = "INFO", warning = "WARN", error = "ERROR"

    private var rank: Int {
        switch self {
        case .debug: return 0
        case .info: return 1
        case .warning: return 2
        case .error: return 3
        }
    }

    public static func < (a: LogLevel, b: LogLevel) -> Bool { a.rank < b.rank }
}

/// One log line: `[12:34:56.123][VM][INFO] Machine started`.
public struct LogLine: Equatable, Sendable {
    public let date: Date
    public let category: LogCategory
    public let level: LogLevel
    public let message: String

    public init(date: Date = Date(), category: LogCategory, level: LogLevel, message: String) {
        self.date = date
        self.category = category
        self.level = level
        self.message = message
    }

    public func formatted(timeZone: TimeZone = .current) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let c = calendar.dateComponents([.hour, .minute, .second, .nanosecond], from: date)
        let ms = (c.nanosecond ?? 0) / 1_000_000
        let time = String(format: "%02d:%02d:%02d.%03d", c.hour ?? 0, c.minute ?? 0, c.second ?? 0, ms)
        // One entry per line: embedded newlines would forge extra entries.
        let body = message.replacingOccurrences(of: "\r", with: "\\r").replacingOccurrences(of: "\n", with: "\\n")
        return "[\(time)][\(category.rawValue)][\(level.rawValue)] \(body)"
    }

    /// Strips things that must not reach a shared diagnostics bundle: the
    /// app container path (contains a per-install UUID) and the user's name.
    public static func redact(_ text: String, homeDirectory: String) -> String {
        guard !homeDirectory.isEmpty else { return text }
        return text.replacingOccurrences(of: homeDirectory, with: "~")
    }
}
