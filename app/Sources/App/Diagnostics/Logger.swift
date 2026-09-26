import Foundation

/// The app's log: `Documents/Logs/app.log`, one LogLine per line, plus the
/// most recent errors in memory for the diagnostics page.
///
/// The previous run's log is kept as app.prev.log, so a crash can be read
/// after relaunching. Debug lines are dropped in release builds.
final class AppLogger {
    static let shared = AppLogger()

    private let queue = DispatchQueue(label: "virtualphone.log")
    private var handle: FileHandle?
    private(set) var recentErrors: [String] = []
    private let maxRecent = 50

    #if DEBUG
    var minimumLevel: LogLevel = .debug
    #else
    var minimumLevel: LogLevel = .info
    #endif

    static var directory: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("Logs")
    }

    static var currentLog: URL { directory.appendingPathComponent("app.log") }
    static var previousLog: URL { directory.appendingPathComponent("app.prev.log") }

    private init() {
        let fm = FileManager.default
        try? fm.createDirectory(at: Self.directory, withIntermediateDirectories: true)
        if fm.fileExists(atPath: Self.currentLog.path) {
            try? fm.removeItem(at: Self.previousLog)
            try? fm.moveItem(at: Self.currentLog, to: Self.previousLog)
        }
        fm.createFile(atPath: Self.currentLog.path, contents: nil)
        handle = try? FileHandle(forWritingTo: Self.currentLog)
    }

    func log(_ category: LogCategory, _ message: String, level: LogLevel = .info) {
        guard level >= minimumLevel else { return }
        let line = LogLine(category: category, level: level, message: message)
        queue.async {
            let text = line.formatted()
            if let data = (text + "\n").data(using: .utf8) { self.handle?.write(data) }
            if level >= .warning {
                self.recentErrors.append(text)
                if self.recentErrors.count > self.maxRecent { self.recentErrors.removeFirst() }
            }
            #if DEBUG
            print(text)
            #endif
        }
    }

    func snapshotRecentErrors() -> [String] {
        queue.sync { recentErrors }
    }

    func flush() {
        queue.sync { try? handle?.synchronize() }
    }
}
