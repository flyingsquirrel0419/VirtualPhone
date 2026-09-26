import Foundation
import Metal

/// In-app checks on the real iOS runtime, run with `-VPSelfTest YES`.
///
/// Linux CI proves the core logic; this proves the same code paths behave on
/// Darwin inside an iOS process — sockets, files, Metal, the JIT probe — where
/// nothing else exercises them before a guest does. Every line it logs starts
/// with SELFTEST so the simulator smoke test (and a user) can read the result.
enum SelfTest {
    static var requested: Bool { UserDefaults.standard.bool(forKey: "VPSelfTest") }

    static func runInBackground() {
        DispatchQueue.global(qos: .utility).async { run() }
    }

    static func run() {
        var passed = 0, failed = 0
        func check(_ name: String, _ body: () throws -> Bool) {
            let ok: Bool
            var detail = ""
            do { ok = try body() } catch { ok = false; detail = " (\(error))" }
            if ok { passed += 1 } else { failed += 1 }
            AppLogger.shared.log(.app, "SELFTEST \(ok ? "PASS" : "FAIL") \(name)\(detail)", level: ok ? .info : .error)
        }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("selftest-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        check("jit-probe") {
            let status = JITProbeRunner.currentStatus()
            AppLogger.shared.log(.jit, "SELFTEST jit: \(status.label) — \(status.detail)")
            return true // any answer without crashing is a pass here
        }

        check("tcp-transfer-roundtrip") {
            let payload = (0..<200_000).map { UInt8($0 % 253) }
            let src = dir.appendingPathComponent("src.bin")
            try Data(payload).write(to: src)
            let server = try FileTransferServer()
            var received = [UInt8]()
            let done = DispatchSemaphore(value: 0)
            Thread {
                if let c = try? TCPConnection.connect(port: server.port) {
                    while let chunk = try? c.readSome() { received += chunk }
                }
                done.signal()
            }.start()
            let sent = try server.send(src, timeout: 5)
            server.close()
            // Read `received` only once the reader has finished with it.
            guard done.wait(timeout: .now() + 5) == .success else { return false }
            var sum = PosixCksum()
            sum.update(payload)
            return received == payload && sent.crc == sum.value
        }

        check("tcp-listener-lines") {
            let listener = try TCPListener()
            Thread {
                if let c = try? TCPConnection.connect(port: listener.port) { try? c.write(Data("one\ntwo\n".utf8)) }
            }.start()
            let conn = try listener.accept(timeout: 5)
            let lines = [try conn.readLine(), try conn.readLine()].map { String(decoding: $0, as: UTF8.self) }
            return lines == ["one", "two"]
        }

        check("console-tailer") {
            let log = dir.appendingPathComponent("console.log")
            let tailer = ConsoleLogTailer(url: log)
            tailer.reset()
            try Data("::\tiBoot for n104ap\nDarwin Kernel Version 20\n".utf8).write(to: log)
            return tailer.poll().transitions.map(\.phase) == [.iboot, .kernel]
        }

        check("overlay-state-snapshot") {
            let docs = dir.appendingPathComponent("docs")
            let data = docs.appendingPathComponent("InfernoData")
            try FileManager.default.createDirectory(at: data.appendingPathComponent("Restore/Firmware/all_flash"), withIntermediateDirectories: true)
            let links = FirmwareLinks()
            let all = GuestFiles.resolve(links, documents: docs, isUsableFile: { _ in true }).files
            for role in GuestFiles.Role.allCases where role != .root {
                try Data("x".utf8).write(to: all.paths[role]!)
            }
            try Data(repeating: 7, count: 1 << 20).write(to: data.appendingPathComponent("root"))
            let resolved = GuestFiles.resolve(links, documents: docs)
            guard resolved.missing.isEmpty else { return false }
            let pkg = try VMPackage.create(in: docs.appendingPathComponent("Devices"), configuration: MachineConfiguration(name: "Self"))
            try DeviceState.prepare(pkg, files: resolved.files)
            let snap = try DeviceSnapshots.take(pkg, name: "t")
            try DeviceSnapshots.restore(pkg, id: snap.id)
            let clone = try pkg.clone(named: "Self 2")
            return QCOW2Overlay.inspect(DeviceState.overlayURL(in: pkg))?.virtualSize == 1 << 20
                && DeviceState.exists(in: clone)
                && DeviceState.resolve(resolved.files, for: pkg).rootFormat == "qcow2"
        }

        check("metal-renderer") {
            guard MTLCreateSystemDefaultDevice() != nil else { return true } // no GPU: nothing to test
            guard let renderer = MetalFrameRenderer() else { return false }
            let pixels = UnsafeMutableRawPointer.allocate(byteCount: 64 * 32 * 4, alignment: 16)
            defer { pixels.deallocate() }
            memset(pixels, 0x7F, 64 * 32 * 4)
            renderer.upload(pixels, width: 64, height: 32)
            return renderer.size == (64, 32)
        }

        check("qmp-codec") {
            QMPCodec.status(from: try QMPCodec.decode(Data(#"{"return": {"status": "running", "running": true}}"#.utf8))) == "running"
        }

        AppLogger.shared.log(.app, "SELFTEST DONE passed=\(passed) failed=\(failed)", level: failed == 0 ? .info : .error)
        AppLogger.shared.flush()
    }
}
