import Foundation
import IOKit
import IOKit.pwr_mgt

/// Holds the system sleep transition until the handoff has been attempted.
/// `NSWorkspace.willSleepNotification` cannot delay sleep; the IOKit power
/// interest notification can, for up to roughly 30 seconds.
final class SleepMonitor {
    /// Called on the main queue when the Mac is about to sleep. The closure
    /// passed in MUST be called once the work is done so sleep can proceed.
    var onWillSleep: ((@escaping () -> Void) -> Void)?
    var onWake: (() -> Void)?

    // IOKit's kIOMessage* macros are not imported into Swift; these are their values
    // (iokit_common_msg(0x270 / 0x280 / 0x300)).
    private static let canSystemSleep: UInt32 = 0xE000_0270
    private static let systemWillSleep: UInt32 = 0xE000_0280
    private static let systemHasPoweredOn: UInt32 = 0xE000_0300

    private var rootPort: io_connect_t = 0
    private var notifier: io_object_t = 0
    private var notifyPort: IONotificationPortRef?

    init() {
        let context = Unmanaged.passUnretained(self).toOpaque()
        rootPort = IORegisterForSystemPower(context, &notifyPort, { refcon, _, messageType, argument in
            guard let refcon else { return }
            let monitor = Unmanaged<SleepMonitor>.fromOpaque(refcon).takeUnretainedValue()
            monitor.handle(messageType: messageType, argument: argument)
        }, &notifier)
        if let port = notifyPort {
            CFRunLoopAddSource(CFRunLoopGetMain(),
                               IONotificationPortGetRunLoopSource(port).takeUnretainedValue(),
                               .commonModes)
        }
    }

    deinit {
        if let port = notifyPort {
            IODeregisterForSystemPower(&notifier)
            IOServiceClose(rootPort)
            IONotificationPortDestroy(port)
        }
    }

    private func handle(messageType: UInt32, argument: UnsafeMutableRawPointer?) {
        let token = Int(bitPattern: argument)
        let port = rootPort
        switch messageType {
        case Self.canSystemSleep:
            IOAllowPowerChange(port, token)
        case Self.systemWillSleep:
            if let onWillSleep {
                DispatchQueue.main.async {
                    onWillSleep { IOAllowPowerChange(port, token) }
                }
            } else {
                IOAllowPowerChange(port, token)
            }
        case Self.systemHasPoweredOn:
            DispatchQueue.main.async { self.onWake?() }
        default:
            break
        }
    }
}
