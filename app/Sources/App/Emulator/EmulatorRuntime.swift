import Foundation

enum RuntimeState: Equatable {
    case idle
    case starting
    case running
    case paused
    case stopping
    case stopped(status: Int32)
    case failed(String)

    var isLive: Bool { self == .running || self == .paused }

    var label: String {
        switch self {
        case .idle: return "Idle"
        case .starting: return "Booting"
        case .running: return "Running"
        case .paused: return "Paused"
        case .stopping: return "Stopping"
        case .stopped: return "Stopped"
        case .failed: return "Failed"
        }
    }
}

enum RuntimeButton: String, CaseIterable, Identifiable {
    case home, side, volumeUp, volumeDown

    var id: String { rawValue }

    var title: String {
        switch self {
        case .home: return "Home"
        case .side: return "Side"
        case .volumeUp: return "Vol+"
        case .volumeDown: return "Vol−"
        }
    }

    var systemImage: String {
        switch self {
        case .home: return "circle"
        case .side: return "power"
        case .volumeUp: return "speaker.plus"
        case .volumeDown: return "speaker.minus"
        }
    }

    /// How long the guest has to see the button held for a tap to count.
    var tapDuration: TimeInterval { 0.2 }
}

struct RuntimeCapabilities: OptionSet {
    let rawValue: UInt32
    static let display = RuntimeCapabilities(rawValue: 1 << 0)
    static let touch = RuntimeCapabilities(rawValue: 1 << 1)
    static let buttons = RuntimeCapabilities(rawValue: 1 << 2)
    static let pause = RuntimeCapabilities(rawValue: 1 << 3)
    static let reset = RuntimeCapabilities(rawValue: 1 << 4)
    static let stop = RuntimeCapabilities(rawValue: 1 << 5)
    static let stats = RuntimeCapabilities(rawValue: 1 << 6)
    static let netStatus = RuntimeCapabilities(rawValue: 1 << 7)
    static let battery = RuntimeCapabilities(rawValue: 1 << 8)
}

struct RuntimeMetrics: Equatable {
    var framesPresented: UInt64 = 0
    var displayRefreshes: UInt64 = 0
    var framesRead: UInt64 = 0
    var touchesSent: UInt64 = 0
    var buttonsSent: UInt64 = 0
    var uptimeMS: UInt64 = 0
    var netLinkUp = false
}

enum FrameReadResult {
    case none
    /// A frame (or part of one) was copied; the whole buffer is current.
    case frame(width: Int, height: Int)
    /// The buffer must be at least this many bytes.
    case resize(width: Int, height: Int)
    case unavailable
}

enum RuntimeError: LocalizedError {
    case libraryMissing
    case load(String)
    case refused(String)

    var errorDescription: String? {
        switch self {
        case .libraryMissing: return "The emulator library is not in this build."
        case .load(let why): return "The emulator library could not be loaded: \(why)"
        case .refused(let why): return why
        }
    }
}

/// What the UI drives. Two implementations: the real emulator
/// (`InfernoRuntime`) and a stand-in that boots in a second (`MockEmulatorRuntime`).
protocol EmulatorRuntime: AnyObject {
    var name: String { get }
    var capabilities: RuntimeCapabilities { get }
    var state: RuntimeState { get }
    /// Delivered on an arbitrary thread.
    var onStateChange: ((RuntimeState) -> Void)? { get set }

    func start(arguments: [String]) throws
    func pause() throws
    func resume() throws
    func reset() throws
    func stop() throws

    /// Copies the current frame into `buffer` (a8r8g8b8). Any thread.
    func readFrame(into buffer: UnsafeMutableRawPointer?, size: Int) -> FrameReadResult
    func touch(x: Int32, y: Int32, pressed: Bool)
    func button(_ button: RuntimeButton, pressed: Bool)
    /// The battery the guest shows. Allowed before start (the SMC keeps it).
    func setBattery(percent: Int32, external: Bool, charging: Bool)
    func metrics() -> RuntimeMetrics
}
