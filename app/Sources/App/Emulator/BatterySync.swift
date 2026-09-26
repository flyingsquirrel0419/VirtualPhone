import UIKit

/// Gives the guest the phone's own battery: charge, cable, charging. The
/// emulated SMC answers with it, so the status bar and Settings in the guest
/// agree with the phone. Updated whenever iOS reports a change.
final class BatterySync {
    private let runtime: EmulatorRuntime
    private var observers: [NSObjectProtocol] = []

    init(runtime: EmulatorRuntime) {
        self.runtime = runtime
    }

    func start() {
        UIDevice.current.isBatteryMonitoringEnabled = true
        push()
        for name in [UIDevice.batteryLevelDidChangeNotification, UIDevice.batteryStateDidChangeNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.push()
            })
        }
    }

    func stop() {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers.removeAll()
    }

    deinit { stop() }

    private func push() {
        let device = UIDevice.current
        // -1 when unknown (the simulator, or monitoring not yet granted): say full.
        let level = device.batteryLevel < 0 ? 100 : Int32((device.batteryLevel * 100).rounded())
        let external = device.batteryState == .charging || device.batteryState == .full
        runtime.setBattery(percent: level, external: external, charging: device.batteryState == .charging)
        AppLogger.shared.log(.guest, "Battery → guest: \(level)%\(external ? ", on power" : "")", level: .debug)
    }
}
