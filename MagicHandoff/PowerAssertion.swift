import Foundation
import IOKit.pwr_mgt
import CoreGraphics

/// Keeps a Mac awake and, when it is only dark-woken (lid closed, display off,
/// network still answering), brings it to a full wake so Bluetooth can pair.
enum PowerAssertion {
    /// True when the display is off: the Mac is asleep or dark-woken. In that
    /// state bluetoothd answers but pairing never completes.
    static var displayIsAsleep: Bool { CGDisplayIsAsleep(CGMainDisplayID()) != 0 }

    /// Declares user activity, which promotes a dark wake to a full wake and
    /// turns the display (or the external monitor in clamshell mode) on.
    static func wakeUp(reason: String) {
        var id = IOPMAssertionID(0)
        IOPMAssertionDeclareUserActivity(reason as CFString, kIOPMUserActiveLocal, &id)
    }

    /// Prevents idle sleep until `release` is called.
    static func holdAwake(reason: String) -> IOPMAssertionID? {
        var id = IOPMAssertionID(0)
        let r = IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
                                            IOPMAssertionLevel(kIOPMAssertionLevelOn), reason as CFString, &id)
        return r == kIOReturnSuccess ? id : nil
    }

    static func release(_ id: IOPMAssertionID?) {
        if let id { IOPMAssertionRelease(id) }
    }
}
