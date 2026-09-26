import CoreGraphics
import Foundation
import SwiftUI

/// Owns one running machine: its runtime, the display pump that turns the
/// framebuffer into images, and the translation of touches and buttons.
///
/// The emulator runs on its own thread (vp_runtime), the pump on another; only
/// published state is touched on the main thread, so the UI never waits for
/// the emulator's lock.
final class EmulatorController: ObservableObject {
    @Published private(set) var state: RuntimeState = .idle
    @Published private(set) var frame: CGImage?
    @Published private(set) var frameSize: (width: Int, height: Int) = (0, 0)
    @Published private(set) var metrics = RuntimeMetrics()
    @Published private(set) var fps: Double = 0
    @Published var lastError: String?

    let package: VMPackage
    let runtime: EmulatorRuntime
    let console: GuestConsole
    private(set) var services: GuestServices!
    var isMock: Bool { runtime is MockEmulatorRuntime }

    private var pump: Thread?
    private let pumpState = PumpState()
    private var metricsTimer: Timer?
    private var touchActive = false

    init(package: VMPackage, runtime: EmulatorRuntime) {
        self.package = package
        self.runtime = runtime
        self.console = GuestConsole(logURL: EmulatorController.consoleLogURL(for: package))
        self.services = GuestServices(console: console, networkUp: { [weak self] in self?.metrics.netLinkUp ?? false })
        runtime.onStateChange = { [weak self] new in
            DispatchQueue.main.async { self?.stateChanged(new) }
        }
    }

    deinit {
        pumpState.running = false
        metricsTimer?.invalidate()
    }

    /// Where `-chardev …,logfile=` writes; EmulatorArguments gets the same path.
    static func consoleLogURL(for package: VMPackage) -> URL {
        package.logsURL.appendingPathComponent("guest-console.log")
    }

    // MARK: - Lifecycle

    func start(arguments: [String]) {
        console.begin()
        if !isMock { package.markRunning() }
        do {
            try runtime.start(arguments: arguments)
        } catch {
            lastError = error.localizedDescription
            state = .failed(error.localizedDescription)
        }
    }

    func togglePause() {
        let paused = state == .paused
        perform {
            if paused { try runtime.resume() } else { try runtime.pause() }
        }
    }

    func restart() { perform { try runtime.reset() } }
    func stop() { perform { try runtime.stop() } }

    private func perform(_ action: () throws -> Void) {
        do { try action() } catch { lastError = error.localizedDescription }
    }

    private func stateChanged(_ new: RuntimeState) {
        state = new
        switch new {
        case .running where pump == nil:
            startPump()
        case .stopped, .failed:
            console.end()
            if !isMock { package.markStopped() }
            pumpState.running = false
            pump = nil
            metricsTimer?.invalidate()
            metricsTimer = nil
            if case .failed(let why) = new { lastError = why }
        default:
            break
        }
    }

    // MARK: - Display

    /// Shared between the pump thread and the controller.
    private final class PumpState {
        private let lock = NSLock()
        private var _running = false
        var running: Bool {
            get { lock.lock(); defer { lock.unlock() }; return _running }
            set { lock.lock(); _running = newValue; lock.unlock() }
        }
    }

    private func startPump() {
        pumpState.running = true
        let runtime = self.runtime
        let state = pumpState
        let thread = Thread { [weak self] in
            EmulatorController.pumpLoop(runtime: runtime, state: state) { image, width, height, fps in
                DispatchQueue.main.async {
                    guard let self else { return }
                    if self.frame == nil { self.console.noteFirstFrame() }
                    self.frame = image
                    if self.frameSize != (width, height) { self.frameSize = (width, height) }
                    self.fps = fps
                }
            }
        }
        thread.name = "virtualphone.display"
        thread.qualityOfService = .userInteractive
        pump = thread
        thread.start()

        metricsTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.metrics = self.runtime.metrics()
            if !self.isMock, Int(self.metrics.uptimeMS / 1000) % 5 == 0 { self.console.refreshQMPStatus() }
        }
    }

    /// Polls at display rate. A pass with nothing new costs one lock inside
    /// the emulator; frames are copied once, into an image SwiftUI owns.
    private static func pumpLoop(runtime: EmulatorRuntime, state: PumpState,
                                 publish: @escaping (CGImage, Int, Int, Double) -> Void) {
        var buffer: UnsafeMutableRawPointer?
        var capacity = 0
        var frames = 0
        var windowStart = Date()
        var fps = 0.0
        defer { buffer?.deallocate() }

        while state.running {
            switch runtime.readFrame(into: buffer, size: capacity) {
            case .resize(let w, let h):
                buffer?.deallocate()
                capacity = w * h * 4
                buffer = UnsafeMutableRawPointer.allocate(byteCount: capacity, alignment: 16)
                continue
            case .frame(let w, let h):
                guard let buffer, let image = makeImage(buffer, width: w, height: h) else { break }
                frames += 1
                let elapsed = Date().timeIntervalSince(windowStart)
                if elapsed >= 1 {
                    fps = Double(frames) / elapsed
                    frames = 0
                    windowStart = Date()
                }
                publish(image, w, h, fps)
            case .none, .unavailable:
                break
            }
            usleep(8_000)
        }
    }

    /// a8r8g8b8 as little-endian words is B,G,R,A in memory.
    private static func makeImage(_ pixels: UnsafeMutableRawPointer, width: Int, height: Int) -> CGImage? {
        let bytes = width * height * 4
        guard let data = CFDataCreate(nil, pixels.assumingMemoryBound(to: UInt8.self), bytes),
              let provider = CGDataProvider(data: data) else { return nil }
        let info = CGBitmapInfo(rawValue: CGBitmapInfo.byteOrder32Little.rawValue
                                | CGImageAlphaInfo.noneSkipFirst.rawValue)
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                       bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: info,
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }

    // MARK: - Input

    /// A finger in the view, in points. Touches that begin on a letterbox bar
    /// are ignored; a drag that began inside is pinned to the edge.
    func touch(at point: CGPoint, in viewSize: CGSize, phase: TouchPhase) {
        guard state == .running, frameSize.width > 0 else { return }
        let mapper = CoordinateMapper(view: Size2D(width: Double(viewSize.width), height: Double(viewSize.height)),
                                      guestWidth: frameSize.width, guestHeight: frameSize.height)
        let p = Point2D(x: Double(point.x), y: Double(point.y))
        switch phase {
        case .began:
            guard let px = mapper.guestPixel(for: p) else { return }
            touchActive = true
            runtime.touch(x: px.x, y: px.y, pressed: true)
        case .moved:
            guard touchActive, let px = mapper.clampedGuestPixel(for: p) else { return }
            runtime.touch(x: px.x, y: px.y, pressed: true)
        case .ended:
            guard touchActive, let px = mapper.clampedGuestPixel(for: p) else { return }
            touchActive = false
            runtime.touch(x: px.x, y: px.y, pressed: false)
        }
    }

    enum TouchPhase { case began, moved, ended }

    /// Holds the button long enough for the guest to register it.
    func press(_ button: RuntimeButton, hold: TimeInterval? = nil) {
        guard state.isLive else { return }
        runtime.button(button, pressed: true)
        AppLogger.shared.log(.input, "Button \(button.title)")
        DispatchQueue.main.asyncAfter(deadline: .now() + (hold ?? button.tapDuration)) { [runtime] in
            runtime.button(button, pressed: false)
        }
    }
}
