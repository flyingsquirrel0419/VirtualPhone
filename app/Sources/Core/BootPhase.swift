import Foundation

/// How far the guest has got, as far as its serial console tells.
public enum BootPhase: Int, Comparable, CaseIterable, Sendable {
    case notStarted = 0
    /// The machine exists; nothing from the guest yet.
    case poweredOn
    /// iBoot is printing.
    case iboot
    /// XNU has started.
    case kernel
    /// The kernel handed over to launchd.
    case launchd
    /// The jailbreak bootstrap's shell answers on the console.
    case shell
    case panicked

    public static func < (a: BootPhase, b: BootPhase) -> Bool { a.rawValue < b.rawValue }

    public var label: String {
        switch self {
        case .notStarted: return "Not started"
        case .poweredOn: return "Powered on"
        case .iboot: return "iBoot"
        case .kernel: return "Kernel"
        case .launchd: return "launchd"
        case .shell: return "Shell ready"
        case .panicked: return "Kernel panic"
        }
    }
}

/// Watches console lines for the markers of each phase.
///
/// Phases only move forward, except that a panic can happen at any time and
/// `reset()` starts over (a guest reboot). Markers are plain substrings, kept in
/// one table so they can be adjusted when a guest prints something else.
public struct BootPhaseDetector: Sendable {
    public struct Transition: Equatable, Sendable {
        public let phase: BootPhase
        public let line: String
        /// Since `start`, in seconds.
        public let elapsed: TimeInterval
    }

    public static let defaultMarkers: [(BootPhase, [String])] = [
        (.iboot, ["iBoot for", "iBoot-", "::\tiBoot"]),
        (.kernel, ["Darwin Kernel Version", "XNU "]),
        (.launchd, ["launchd", "BSD root:"]),
        (.shell, ["bash-", "VP-SHELL-READY"]),
    ]
    public static let panicMarkers = ["panic(cpu", "Kernel panic", "panicked task"]
    /// Lines that are not a phase but worth surfacing.
    public static let warningMarkers = ["Still waiting for root device", "RAM Disk required for recovery"]

    public private(set) var phase: BootPhase = .notStarted
    public private(set) var transitions: [Transition] = []
    public private(set) var warnings: [String] = []
    private var startedAt: Date?
    private let markers: [(BootPhase, [String])]

    public init(markers: [(BootPhase, [String])] = BootPhaseDetector.defaultMarkers) {
        self.markers = markers
    }

    public mutating func start(at date: Date = Date()) {
        startedAt = date
        phase = .poweredOn
        transitions = [Transition(phase: .poweredOn, line: "", elapsed: 0)]
        warnings = []
    }

    public mutating func reset(at date: Date = Date()) { start(at: date) }

    /// Feeds one console line; returns the transition it caused, if any.
    @discardableResult
    public mutating func observe(_ line: String, at date: Date = Date()) -> Transition? {
        if startedAt == nil { start(at: date) }
        let elapsed = date.timeIntervalSince(startedAt ?? date)

        if Self.warningMarkers.contains(where: line.contains), !warnings.contains(line) {
            warnings.append(line)
        }
        if phase != .panicked, Self.panicMarkers.contains(where: line.contains) {
            return advance(to: .panicked, line: line, elapsed: elapsed)
        }
        guard phase != .panicked else { return nil }
        // The furthest phase this line proves; earlier markers are implied.
        var best: BootPhase?
        for (candidate, needles) in markers where candidate > phase {
            if needles.contains(where: line.contains) { best = max(best ?? candidate, candidate) }
        }
        guard let next = best else { return nil }
        return advance(to: next, line: line, elapsed: elapsed)
    }

    private mutating func advance(to next: BootPhase, line: String, elapsed: TimeInterval) -> Transition {
        phase = next
        let t = Transition(phase: next, line: line, elapsed: elapsed)
        transitions.append(t)
        return t
    }

    /// Seconds from power-on to the first time `phase` was reached.
    public func time(to target: BootPhase) -> TimeInterval? {
        transitions.first { $0.phase == target }?.elapsed
    }
}
