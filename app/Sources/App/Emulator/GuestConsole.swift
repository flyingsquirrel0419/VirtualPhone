import Foundation
import SwiftUI

/// The guest's serial console for the UI: follows the console log, tracks boot
/// phases, and types into the console over the chardev socket.
///
/// Reading and phase detection happen on a private queue; only the published
/// snapshot is touched on the main thread.
final class GuestConsole: ObservableObject {
    @Published private(set) var lines: [String] = []
    @Published private(set) var phase: BootPhase = .notStarted
    @Published private(set) var transitions: [BootPhaseDetector.Transition] = []
    @Published private(set) var warnings: [String] = []
    @Published private(set) var qmpStatus: String?
    @Published private(set) var firstFrameAfter: TimeInterval?

    let logURL: URL
    let serialPort: UInt16
    let qmpPort: UInt16
    /// Lines kept for display; the tailer keeps more for export.
    let visibleLines = 800

    private let tailer: ConsoleLogTailer
    private let queue = DispatchQueue(label: "virtualphone.console")
    private var timer: DispatchSourceTimer?
    private var input: TCPConnection?
    private var startedAt: Date?
    /// Called on the console queue for every completed line.
    private var observers: [UUID: (String) -> Void] = [:]

    init(logURL: URL, serialPort: UInt16 = 4555, qmpPort: UInt16 = 4556) {
        self.logURL = logURL
        self.serialPort = serialPort
        self.qmpPort = qmpPort
        self.tailer = ConsoleLogTailer(url: logURL)
    }

    deinit { timer?.cancel() }

    /// Empties the log and starts following it. Call before the machine starts.
    func begin() {
        let now = Date()
        startedAt = now
        firstFrameAfter = nil
        timer?.cancel()
        queue.sync {
            try? FileManager.default.createDirectory(at: logURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            tailer.reset(at: now)
        }
        publish()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 0.25, repeating: 0.25)
        timer.setEventHandler { [weak self] in self?.tick() }
        self.timer = timer
        timer.resume()
        AppLogger.shared.log(.boot, "Console: following \(logURL.lastPathComponent)")
    }

    /// One last read, then stop following.
    func end() {
        queue.async { [weak self] in
            self?.tick()
            self?.timer?.cancel()
            self?.timer = nil
            self?.input?.close()
            self?.input = nil
        }
    }

    /// Every completed console line from now on, on a private queue.
    func observeLines(_ handler: @escaping (String) -> Void) -> UUID {
        let id = UUID()
        queue.async { self.observers[id] = handler }
        return id
    }

    func removeObserver(_ id: UUID) {
        queue.async { self.observers[id] = nil }
    }

    private func tick() {
        let update = tailer.poll()
        for line in update.lines { observers.values.forEach { $0(line) } }
        for t in update.transitions {
            AppLogger.shared.log(.boot, String(format: "%@ after %.1f s: %@", t.phase.label, t.elapsed, String(t.line.prefix(120))),
                                 level: t.phase == .panicked ? .error : .info)
        }
        if !update.lines.isEmpty || !update.transitions.isEmpty { publish() }
    }

    /// Called on the console queue or at begin().
    private func publish() {
        let snapshot = Array(tailer.buffer.lines.suffix(visibleLines)) + (tailer.buffer.pending.isEmpty ? [] : [tailer.buffer.pending])
        let phase = tailer.detector.phase
        let transitions = tailer.detector.transitions
        let warnings = tailer.detector.warnings
        DispatchQueue.main.async {
            self.lines = snapshot
            self.phase = phase
            self.transitions = transitions
            self.warnings = warnings
        }
    }

    func noteFirstFrame() {
        guard firstFrameAfter == nil, let startedAt else { return }
        let elapsed = Date().timeIntervalSince(startedAt)
        firstFrameAfter = elapsed
        AppLogger.shared.log(.display, String(format: "First frame after %.1f s", elapsed))
    }

    /// Types a line into the guest's console (a newline is sent as CR, as a
    /// terminal would). Connects lazily; a failed connection is retried next time.
    func send(_ line: String, completion: @escaping (String?) -> Void) {
        let port = serialPort
        queue.async { [weak self] in
            guard let self else { return }
            do {
                if self.input == nil || self.input?.isOpen == false {
                    self.input = try TCPConnection.connect(port: port, timeout: 2)
                }
                try self.input?.write(Data((line + "\r").utf8))
                DispatchQueue.main.async { completion(nil) }
            } catch {
                self.input?.close()
                self.input = nil
                DispatchQueue.main.async { completion("Console input failed: \(error)") }
            }
        }
    }

    /// Asks QEMU for its run state over QMP (not the bridge's view of it).
    func refreshQMPStatus() {
        let port = qmpPort
        DispatchQueue.global(qos: .utility).async {
            let status: String
            do { status = try QMPClient.connect(port: port, timeout: 1.5).status() } catch { status = "unreachable" }
            DispatchQueue.main.async { self.qmpStatus = status }
        }
    }

    /// Writes the whole console to a file off the main thread, then hands its URL back on main.
    func export(_ completion: @escaping (URL?) -> Void) {
        queue.async {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("guest-console.txt")
            let ok = (try? self.tailer.buffer.text.write(to: url, atomically: true, encoding: .utf8)) != nil
            DispatchQueue.main.async { completion(ok ? url : nil) }
        }
    }
}
