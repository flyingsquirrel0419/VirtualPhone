import Darwin
import Foundation

/// Something that can give this process executable memory. VirtualPhone does
/// not depend on any one of them: each only explains how the user turns JIT on,
/// and the probe below decides whether it worked.
protocol JITProvider {
    var id: String { get }
    var name: String { get }
    var instructions: String { get }
}

struct ExternalDebugProvider: JITProvider {
    let id = "external-debugger"
    let name = "External debugger"
    let instructions = "Attach any debugger that enables JIT (Xcode, lldb over a pairing record), then return to the app."
}

struct StikDebugCompatibleProvider: JITProvider {
    let id = "stikdebug"
    let name = "StikDebug-compatible"
    let instructions = "Launch VirtualPhone from StikDebug (with its loopback VPN and your pairing file set up). Assign the legacy script if the tool asks for one."
}

struct SideStoreCompatibleProvider: JITProvider {
    let id = "sidestore"
    let name = "SideStore-compatible"
    let instructions = "Use the sideloading tool's Enable JIT action on VirtualPhone, then return to the app."
}

enum JITProviders {
    static let all: [JITProvider] = [StikDebugCompatibleProvider(), SideStoreCompatibleProvider(), ExternalDebugProvider()]
}

/// Probes the host the same way TCG will allocate.
enum JITProbeRunner {
    private static let MAP_JIT_FLAG: Int32 = 0x800

    static func isBeingDebugged() -> Bool {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        guard sysctl(&mib, u_int(mib.count), &info, &size, nil, 0) == 0 else { return false }
        return (info.kp_proc.p_flag & P_TRACED) != 0
    }

    /// MAP_JIT is granted for the JIT entitlement or a debugged process.
    static func canMapJIT() -> Bool {
        let size = Int(getpagesize())
        let addr = mmap(nil, size, PROT_NONE, MAP_PRIVATE | MAP_ANONYMOUS | MAP_JIT_FLAG, -1, 0)
        guard addr != MAP_FAILED else { return false }
        munmap(addr, size)
        return true
    }

    /// What split-wx is built on: RW memory that may later become RX.
    static func canMirrorMap() -> Bool {
        let size = Int(getpagesize())
        let addr = mmap(nil, size, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0)
        guard addr != MAP_FAILED, let page = addr else { return false }
        defer { munmap(page, size) }
        return mprotect(page, size, PROT_READ | PROT_EXEC) == 0
    }

    static func probe() -> JITProbe {
        JITProbe(debuggerAttached: isBeingDebugged(), mapJITAllowed: canMapJIT(), mirrorMapAllowed: canMirrorMap())
    }

    /// Cheap and repeatable: a debugger may attach after launch, so the app
    /// re-probes whenever it becomes active.
    static func currentStatus() -> JITStatus {
        let probe = probe()
        let provider = probe.debuggerAttached ? "debugger" : (probe.mapJITAllowed ? "entitlement" : "none")
        return probe.status(provider: provider)
    }
}
