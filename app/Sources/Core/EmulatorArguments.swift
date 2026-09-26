import Foundation

/// Builds the emulator's command line from a configuration.
///
/// Pure: everything it depends on is passed in, so the exact argv a machine
/// will get is unit-tested on Linux. The layout follows the T8030 machine in
/// Inferno and what Inferno-iOS established on real phones (docs/UPSTREAM.md).
public struct EmulatorArguments {
    public struct Options: Equatable, Sendable {
        /// Translation buffer mapped twice (RW + RX) — needed when MAP_JIT is
        /// refused but a debugger lets pages change protection.
        public var splitWX: Bool
        /// QEMU's data directory (keymaps), inside the app bundle.
        public var qemuDataDirectory: String
        public var consoleLogPath: String
        public var serialPort: Int
        public var qmpPort: Int
        /// AF_UNIX sun_path holds 104 bytes; the emulator runs with its working
        /// directory set to the socket's folder and gets a bare name.
        public var usbSocketName: String

        public init(splitWX: Bool, qemuDataDirectory: String, consoleLogPath: String,
                    serialPort: Int = 4555, qmpPort: Int = 4556, usbSocketName: String = "usb.sock") {
            self.splitWX = splitWX
            self.qemuDataDirectory = qemuDataDirectory
            self.consoleLogPath = consoleLogPath
            self.serialPort = serialPort
            self.qmpPort = qmpPort
            self.usbSocketName = usbSocketName
        }
    }

    public enum BuildError: Error, Equatable {
        case invalidConfiguration([String])
        case missingFiles([GuestFiles.Role])
    }

    /// NVMe namespaces besides root and nvram, in the order the machine expects.
    static let namespaces: [(role: GuestFiles.Role, id: String, nsid: Int, nstype: Int)] = [
        (.firmware, "firmware", 2, 2),
        (.syscfg, "syscfg", 3, 3),
        (.ctrlBits, "ctrl_bits", 4, 4),
        (.effaceable, "effaceable", 6, 6),
        (.panicLog, "panic_log", 7, 8),
    ]
    static let blockSizes = "logical_block_size=4096,physical_block_size=4096"

    public static func build(
        config: MachineConfiguration,
        files: GuestFiles,
        missing: [GuestFiles.Role] = [],
        options: Options
    ) throws -> [String] {
        let errors = config.validate().compactMap { issue -> String? in
            if case .error(let message) = issue { return message }
            return nil
        }
        guard errors.isEmpty else { throw BuildError.invalidConfiguration(errors) }
        guard missing.isEmpty else { throw BuildError.missingFiles(missing) }

        let preset = config.displayPreset
        let machine = [
            "t8030",
            "usb-uplink-type=inferno",
            "usb-uplink-addr=unix:\(options.usbSocketName)",
            "trustcache=\(files.path(.trustCache))",
            "ticket=\(files.path(.ticket))",
            "sep-fw=\(files.path(.sepFirmware))",
            "sep-rom=\(files.path(.sepROM))",
            "kaslr-off=true",
            // Said every run: NVRAM left by an unfinished restore can say
            // auto-boot=false, and the machine then heads for recovery.
            "boot-mode=exit_recovery",
            "disp-width=\(preset.width)",
            "disp-height=\(preset.height)",
            "disp-scale=\(preset.scale)",
        ].joined(separator: ",")

        // Always multi-threaded: on one thread the SEP and AP cores cannot
        // move together and the SEP panics initialising its key store.
        let accel = "tcg,thread=multi,tb-size=\(config.translatorCacheMB)"
            + (options.splitWX ? ",split-wx=on" : "")

        var argv = [
            "qemu-system-aarch64",
            "-L", options.qemuDataDirectory,
            "-accel", accel,
            "-M", machine,
            "-kernel", files.path(.kernel),
            "-dtb", files.path(.deviceTree),
            "-append", config.effectiveBootArgs,
            "-smp", String(config.cpuCores),
            "-m", "\(config.memoryMB)M",
            "-chardev", "socket,id=serial0,host=127.0.0.1,port=\(options.serialPort),server=on,wait=off,"
                + "logfile=\(options.consoleLogPath),logappend=on",
            "-serial", "chardev:serial0",
            "-qmp", "tcp:127.0.0.1:\(options.qmpPort),server,nowait",
            "-drive", "file=\(files.path(.sepNVRAM)),if=pflash,format=raw",
            "-drive", "file=\(files.path(.sepSSC)),if=pflash,format=raw",
        ]

        if !config.audio {
            // Long form on purpose: the short one splits `apple.mca` at its dot.
            argv += ["-audiodev", "none,id=quiet",
                     "-global", "driver=apple.mca,property=audiodev,value=quiet"]
        }

        // The app reads the framebuffer in-process; nothing to serve.
        argv += ["-display", "none"]

        argv += ["-drive", "file=\(files.path(.root)),format=\(files.rootFormat),if=none,id=root",
                 "-device", "nvme-ns,drive=root,bus=nvme-bus.0,nsid=1,nstype=1,\(blockSizes)"]
        for ns in namespaces {
            argv += ["-drive", "file=\(files.path(ns.role)),format=raw,if=none,id=\(ns.id)",
                     "-device", "nvme-ns,drive=\(ns.id),bus=nvme-bus.0,nsid=\(ns.nsid),nstype=\(ns.nstype),\(blockSizes)"]
        }

        if config.network {
            argv += ["-netdev", "user,id=net0",
                     "-device", "apple-ncm-host,netdev=net0,conn-addr=\(options.usbSocketName)"]
        }

        argv += ["-drive", "file=\(files.path(.nvram)),if=none,format=raw,id=nvram",
                 "-device", "apple-nvram,drive=nvram,bus=nvme-bus.0,nsid=5,nstype=5,id=nvram,\(blockSizes)"]
        return argv
    }
}
