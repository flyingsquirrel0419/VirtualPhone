import Foundation
import SwiftUI

/// Runs one shell command at a time on the guest's console and waits for its
/// framed result. Blocking; call from a worker thread, never the main one.
final class GuestShellSession: GuestTransport {
    let name = "console"
    private let console: GuestConsole
    private let lock = NSLock()

    init(console: GuestConsole) { self.console = console }

    /// The console shell exists once the bootstrap's bash has answered.
    var isConnected: Bool {
        // `phase` is main-thread state; never sync onto main from main.
        let phase = Thread.isMainThread ? console.phase : DispatchQueue.main.sync { console.phase }
        return phase >= .shell && phase != .panicked
    }

    func run(_ command: String, timeout: TimeInterval = 120) -> ShellFrame.Result? {
        lock.lock()
        defer { lock.unlock() }
        let frame = ShellFrame()
        var parser = ShellFrame.Parser(frame: frame)
        var result: ShellFrame.Result?
        let done = DispatchSemaphore(value: 0)
        let observer = console.observeLines { line in
            guard result == nil, let r = parser.feed(line) else { return }
            result = r
            done.signal()
        }
        defer { console.removeObserver(observer) }
        var sendError: String?
        let sent = DispatchSemaphore(value: 0)
        console.send(frame.wrap(command)) { sendError = $0; sent.signal() }
        sent.wait()
        if let sendError {
            AppLogger.shared.log(.guest, sendError, level: .error)
            return nil
        }
        guard done.wait(timeout: .now() + timeout) == .success else {
            AppLogger.shared.log(.guest, "Command timed out after \(Int(timeout)) s: \(command.prefix(80))", level: .warning)
            return nil
        }
        return result
    }
}

/// What the app does inside the guest: network recovery, files, apps.
/// Each operation reports progress lines and ends with success or a reason.
final class GuestServices: ObservableObject {
    enum Outcome: Equatable {
        case running
        case succeeded(String)
        case failed(String)
    }

    @Published private(set) var title = ""
    @Published private(set) var progress: [String] = []
    @Published private(set) var outcome: Outcome?

    private let console: GuestConsole
    private let consoleShell: GuestShellSession
    private var networkShell: NetworkShellTransport?
    private let networkUp: () -> Bool
    private let worker = DispatchQueue(label: "virtualphone.guest")

    init(console: GuestConsole, networkUp: @escaping () -> Bool) {
        self.console = console
        self.consoleShell = GuestShellSession(console: console)
        self.networkUp = networkUp
    }

    /// The network shell when it can be had, the console otherwise. On a worker thread.
    private var shell: GuestTransport {
        if networkShell?.isConnected != true, networkUp() {
            networkShell = connectNetworkShell()
        }
        let candidates: [GuestTransport?] = [networkShell, consoleShell]
        return FallbackTransport(candidates.compactMap { $0 })
    }

    /// Asks the guest (over the console) to call back with a bash on a socket.
    private func connectNetworkShell() -> NetworkShellTransport? {
        guard consoleShell.isConnected, let transport = try? NetworkShellTransport() else { return nil }
        let typed = DispatchSemaphore(value: 0)
        console.send(transport.callbackCommand) { _ in typed.signal() }
        typed.wait()
        do {
            try transport.accept(timeout: 20)
            note("Shell connected over the guest's network.")
            return transport
        } catch {
            AppLogger.shared.log(.guest, "Network shell did not call back; using the console", level: .warning)
            transport.close()
            return nil
        }
    }

    var isBusy: Bool { outcome == .running }

    private func begin(_ title: String) -> Bool {
        guard !isBusy else { return false }
        self.title = title
        progress = []
        outcome = .running
        AppLogger.shared.log(.guest, title)
        return true
    }

    private func note(_ line: String) {
        AppLogger.shared.log(.guest, line)
        DispatchQueue.main.async { self.progress.append(line) }
    }

    private func finish(_ outcome: Outcome) {
        if case .failed(let why) = outcome { AppLogger.shared.log(.guest, "Failed: \(why)", level: .error) }
        DispatchQueue.main.async { self.outcome = outcome }
    }

    /// The console shell is only there once the bootstrap's bash answers.
    private func requireShell() -> String? {
        console.phase >= .shell && console.phase != .panicked
            ? nil : "The guest is offline: its shell has not come up on the console yet (phase: \(console.phase.label))."
    }

    // MARK: - Network

    func reconnectNetwork() {
        guard begin("Reconnect guest network") else { return }
        let offline = requireShell()
        worker.async { [self] in
            if let offline { return finish(.failed(offline)) }
            note("Running `\(GuestCommand.reconnectNetwork)` in the guest…")
            guard let r = shell.run(GuestCommand.reconnectNetwork, timeout: 60) else {
                return finish(.failed("No answer from the guest shell."))
            }
            r.output.forEach(note)
            finish(r.status == 0 ? .succeeded("The guest asked for a new address.") : .failed("ipconfig exited with \(r.status)."))
        }
    }

    // MARK: - Files

    /// Moves `file` into the guest at `guestPath` over slirp, checked with cksum.
    private func transfer(_ file: URL, to guestPath: String) throws -> (UInt32, Int64) {
        let server = try FileTransferServer()
        var served: Result<(crc: UInt32, length: Int64), Error>?
        let serving = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            served = Result { try server.send(file, timeout: 90) }
            serving.signal()
        }
        note("Guest fetching over its network (port \(server.port))…")
        let r = shell.run(GuestCommand.receiveFile(port: server.port, to: guestPath), timeout: 900)
        server.close()
        serving.wait()
        guard let r else { throw GuestError("No answer from the guest shell while it received the file.") }
        if let why = GuestCommand.diagnose(r.output) { throw GuestError(why) }
        guard r.status == 0 else { throw GuestError("Receiving in the guest failed with status \(r.status).") }
        guard case .success(let sent)? = served else { throw GuestError("The guest never connected to fetch the file.") }
        guard let guestSum = r.output.compactMap(PosixCksum.parse).last else { throw GuestError("The guest did not report a checksum.") }
        guard guestSum.crc == sent.crc, guestSum.length == sent.length else {
            throw GuestError("Checksum mismatch: sent \(sent.length) bytes (\(sent.crc)), guest has \(guestSum.length) (\(guestSum.crc)).")
        }
        note("Transferred \(ByteCountFormatter.string(fromByteCount: sent.length, countStyle: .file)); checksums match.")
        return (sent.crc, sent.length)
    }

    func sendFile(_ url: URL, toDirectory directory: String = "/var/mobile/Documents") {
        guard begin("Send \(url.lastPathComponent) to the guest") else { return }
        let offline = requireShell(), networkUp = networkUp()
        worker.async { [self] in
            if let offline { return finish(.failed(offline)) }
            if !networkUp { return finish(.failed("The guest network is down. Use Reconnect Guest Network first.")) }
            let accessing = url.startAccessingSecurityScopedResource()
            defer { if accessing { url.stopAccessingSecurityScopedResource() } }
            do {
                let target = directory + "/" + url.lastPathComponent
                _ = try transfer(url, to: target)
                finish(.succeeded("Saved as \(target) in the guest."))
            } catch {
                finish(.failed(error.localizedDescription))
            }
        }
    }

    /// Copies `guestPath` out of the guest into Documents/FromGuest.
    func fetchFile(_ guestPath: String) {
        guard begin("Fetch \((guestPath as NSString).lastPathComponent) from the guest") else { return }
        let offline = requireShell(), networkUp = networkUp()
        worker.async { [self] in
            if let offline { return finish(.failed(offline)) }
            if !networkUp { return finish(.failed("The guest network is down. Use Reconnect Guest Network first.")) }
            do {
                let folder = AppModel.documents.appendingPathComponent("FromGuest", isDirectory: true)
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                let target = folder.appendingPathComponent((guestPath as NSString).lastPathComponent)
                let server = try FileTransferServer()
                var received: Result<(crc: UInt32, length: Int64), Error>?
                let done = DispatchSemaphore(value: 0)
                DispatchQueue.global(qos: .userInitiated).async {
                    received = Result { try server.receive(to: target, timeout: 90) }
                    done.signal()
                }
                let r = shell.run(GuestCommand.sendFile(guestPath, port: server.port), timeout: 900)
                done.wait()
                server.close()
                guard let r else { throw GuestError("No answer from the guest shell.") }
                if let why = GuestCommand.diagnose(r.output) { throw GuestError(why) }
                guard r.status == 0 else { throw GuestError("Sending from the guest failed with status \(r.status).") }
                guard case .success(let got)? = received,
                      let sum = r.output.compactMap(PosixCksum.parse).last, sum.crc == got.crc, sum.length == got.length
                else { throw GuestError("The file arrived incomplete or its checksum does not match.") }
                finish(.succeeded("Saved to Files → VirtualPhone → FromGuest → \(target.lastPathComponent)."))
            } catch {
                finish(.failed(error.localizedDescription))
            }
        }
    }

    // MARK: - IPA

    func installIPA(_ url: URL) {
        guard begin("Install \(url.lastPathComponent)") else { return }
        let offline = requireShell(), networkUp = networkUp()
        worker.async { [self] in
            let accessing = url.startAccessingSecurityScopedResource()
            defer { if accessing { url.stopAccessingSecurityScopedResource() } }
            note("Checking the IPA…")
            let report = IPAInspector.inspect(url)
            if !report.isInstallable { return finish(.failed(report.problems.map(\.message).joined(separator: "\n"))) }
            note("\(report.name) \(report.version) (\(report.bundleID)), \(report.architectures.joined(separator: ", ")), iOS \(report.minimumOS)+")
            if let offline { return finish(.failed(offline)) }
            if !networkUp { return finish(.failed("The guest network is down. Use Reconnect Guest Network first.")) }

            let staging = FileManager.default.temporaryDirectory.appendingPathComponent("vp-install-\(UUID().uuidString).tar")
            defer { try? FileManager.default.removeItem(at: staging) }
            do {
                note("Unpacking on the phone…")
                _ = try IPAInspector.makeGuestTar(from: url, report: report, to: staging)
                let guestTar = "/tmp/vp-install.tar"
                _ = try transfer(staging, to: guestTar)
                let appName = String(report.appDirectory.dropFirst("Payload/".count))
                for step in GuestCommand.installSteps(tar: guestTar, appName: appName) {
                    note(step.label + "…")
                    guard let r = shell.run(step.command, timeout: 600) else {
                        if step.critical { throw GuestError("No answer from the guest during: \(step.label).") }
                        continue
                    }
                    if step.critical, r.status != 0 {
                        throw GuestError(GuestCommand.diagnose(r.output) ?? "\(step.label) failed with status \(r.status).")
                    }
                }
                finish(.succeeded("\(report.name) is installed. It appears on the guest's home screen."))
            } catch {
                finish(.failed(error.localizedDescription))
            }
        }
    }
}

struct GuestError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
