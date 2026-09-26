import Foundation

/// Whether this process can execute code it wrote — what TCG needs.
public enum JITStatus: Equatable, Sendable {
    case unavailable(reason: String)
    case requesting(provider: String)
    case enabled(method: JITMethod, provider: String)
    case verificationFailed(reason: String)

    public var isEnabled: Bool {
        if case .enabled = self { return true }
        return false
    }

    public var label: String {
        switch self {
        case .unavailable: return "JIT unavailable"
        case .requesting: return "JIT requesting"
        case .enabled: return "JIT enabled"
        case .verificationFailed: return "JIT verification failed"
        }
    }

    public var detail: String {
        switch self {
        case .unavailable(let reason), .verificationFailed(let reason): return reason
        case .requesting(let provider): return "waiting for \(provider)"
        case .enabled(let method, let provider): return "\(method.rawValue) via \(provider)"
        }
    }
}

/// How executable memory is obtained, which decides TCG's buffer layout.
public enum JITMethod: String, Equatable, Sendable {
    /// MAP_JIT granted: one RWX translation buffer.
    case mapJIT = "MAP_JIT"
    /// MAP_JIT refused but mprotect to RX allowed (debugger attached):
    /// the buffer is mapped twice, `split-wx=on`.
    case splitWX = "split-wx"

    public var needsSplitWX: Bool { self == .splitWX }
}

/// Raw results of the host probes, so the decision is testable without a phone.
public struct JITProbe: Equatable, Sendable {
    public var debuggerAttached: Bool
    public var mapJITAllowed: Bool
    public var mirrorMapAllowed: Bool
    /// nil when the execution test was not run.
    public var executionVerified: Bool?

    public init(debuggerAttached: Bool, mapJITAllowed: Bool, mirrorMapAllowed: Bool, executionVerified: Bool? = nil) {
        self.debuggerAttached = debuggerAttached
        self.mapJITAllowed = mapJITAllowed
        self.mirrorMapAllowed = mirrorMapAllowed
        self.executionVerified = executionVerified
    }

    public func status(provider: String) -> JITStatus {
        if executionVerified == false {
            return .verificationFailed(reason: "memory was granted but generated code did not run")
        }
        if mapJITAllowed { return .enabled(method: .mapJIT, provider: provider) }
        if mirrorMapAllowed { return .enabled(method: .splitWX, provider: provider) }
        if debuggerAttached {
            return .verificationFailed(reason: "a debugger is attached but executable memory is still refused")
        }
        return .unavailable(reason: "launch VirtualPhone through a JIT enabler (see docs/JIT.md)")
    }
}
