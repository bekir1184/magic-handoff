import Foundation
import IOKit.hid
import CoreGraphics
import Combine
import AppKit

/// Uses the Magic Keyboard's Caps Lock LED as a status light.
///
/// Timing follows indicator-light practice: IEC 60073 puts a "normal" flash at
/// 1.4–2.8 Hz and human-factors guides (FAA HFDS, MIL-STD-1472) ask for
/// 0.8–5 Hz, at most two distinct rates, nothing above 3 Hz, pulses of at
/// least ~100 ms to read as a flash, and a long pulse at least twice a short
/// one so the two are told apart. Bluetooth devices use a steady fast blink for
/// "searching" and a short confirmation followed by a solid light for
/// "connected".
///
/// How the LED is driven: the keyboard's event driver (AppleHIDKeyboardEventDriver)
/// owns the Caps Lock LED and re-sends its own idea of the state whenever it
/// feels like it, which fights a raw HID output report. Its `HIDCapsLockLED`
/// service property ("on" / "off" / "auto") makes the driver itself hold the
/// LED where we want it. The raw output report (report 1, LED usage bit 2)
/// remains as a fallback when the service cannot be reached.
final class CapsLockIndicator: ObservableObject {
    /// Mirrors what the keyboard LED was last told to do, for on-screen previews.
    @Published private(set) var ledOn = false

    private let queue = DispatchQueue(label: "com.bekirersever.magichandoff.capslock")
    private var generation = 0          // bumping it cancels the running animation
    private var loadingActive = false
    var logger: ((String) -> Void)?
    var enabled = true

    enum Method: String, CaseIterable {
        /// HID output report only (needs Input Monitoring). The keyboard driver may override it.
        case raw
        /// Output report, with the driver's own LED handling inhibited for the duration.
        case rawInhibit
        /// Ask the driver to hold the LED via its HIDCapsLockLED property.
        case driver

        var label: String {
            switch self {
            case .raw: return "Raw report"
            case .rawInhibit: return "Raw report + inhibit driver"
            case .driver: return "Driver property"
            }
        }
    }
    var method: Method = .rawInhibit

    // MARK: - Public

    /// Searching: calm 1 Hz blink (500 ms on / 500 ms off) until `stopLoading()` or `playConnected()`.
    func startLoading() {
        guard enabled else { return }
        queue.async {
            guard !self.loadingActive else { return }
            self.loadingActive = true
            self.generation += 1
            self.resetStats()
            self.beginTakeover()
            self.loop(generation: self.generation)
        }
    }

    func stopLoading() {
        queue.async {
            let wasLoading = self.loadingActive
            self.loadingActive = false
            self.generation += 1
            self.restore()
            if wasLoading { self.reportStats("Searching") }
        }
    }

    /// Connected: two short pulses (120 ms, "thump-thump"), a beat of silence,
    /// then one long solid flash (700 ms), then off and back to the real Caps
    /// Lock state.
    func playConnected() {
        guard enabled else { return }
        queue.async {
            self.loadingActive = false
            self.generation += 1
            let g = self.generation
            let pattern: [(on: Bool, ms: Int)] = [
                (true, 120), (false, 120),
                (true, 120), (false, 250),
                (true, 700), (false, 0),
            ]
            self.resetStats()
            self.beginTakeover()
            self.play(pattern, generation: g) { self.restore(); self.reportStats("Connected") }
        }
    }

    /// Stop any animation and leave the LED lit — used right before the keyboard
    /// is handed away, so it stays on for as long as the firmware keeps it.
    func holdOn() {
        guard enabled else { return }
        queue.async {
            self.loadingActive = false
            self.generation += 1
            self.setLED(true)
        }
    }

    /// One short blink, e.g. when handing the keyboard away.
    func playGoodbye() {
        guard enabled else { return }
        queue.async {
            self.generation += 1
            let g = self.generation
            self.beginTakeover()
            self.play([(true, 300), (false, 0)], generation: g) { self.restore() }
        }
    }

    // MARK: - Animation engine (runs on `queue`)

    private func loop(generation g: Int) {
        guard g == generation, loadingActive else { return }
        play([(true, 500), (false, 500)], generation: g) {
            self.loop(generation: g)
        }
    }

    /// Timing statistics for the last pattern, to tell our jitter from the keyboard's.
    private var lateMax = 0.0        // how late a step fired vs its planned time (ms)
    private var writeMax = 0.0       // longest LED write call (ms)
    private var writeTotal = 0.0
    private var writeCount = 0

    /// While a step lasts, its state is re-sent this often so that anything else
    /// touching the LED (the keyboard driver, the firmware) is overruled within
    /// one interval instead of leaving a visible gap.
    private static let holdInterval = 50

    private func play(_ steps: [(on: Bool, ms: Int)], generation g: Int, done: @escaping () -> Void) {
        // Steps are scheduled against one fixed start time, so a slow write
        // never pushes the following steps later.
        let start = DispatchTime.now()
        var offsetMs = 0
        var pending = steps.count
        for step in steps {
            let planned = start + .milliseconds(offsetMs)
            let stepStart = offsetMs
            offsetMs += step.ms
            queue.asyncAfter(deadline: planned) {
                guard g == self.generation else { return }
                let lateMs = Double(DispatchTime.now().uptimeNanoseconds - planned.uptimeNanoseconds) / 1_000_000
                self.lateMax = max(self.lateMax, lateMs)
                self.setLED(step.on)
                pending -= 1
                if pending == 0 {
                    self.queue.asyncAfter(deadline: start + .milliseconds(offsetMs)) {
                        guard g == self.generation else { return }
                        done()
                    }
                }
            }
            // Re-assert the state for the rest of the step.
            var t = stepStart + Self.holdInterval
            while t < stepStart + step.ms - 10 {
                let at = start + .milliseconds(t)
                queue.asyncAfter(deadline: at) {
                    guard g == self.generation else { return }
                    self.reassert(step.on)
                }
                t += Self.holdInterval
            }
        }
    }

    /// Same state again, without touching the on-screen mirror or the stats.
    private func reassert(_ on: Bool) {
        switch method {
        case .driver:
            if let service = keyboardService() {
                _ = IOHIDServiceClientSetProperty(service, Self.capsLockLEDKey as CFString, (on ? "on" : "off") as CFString)
            }
        case .raw, .rawInhibit:
            writeRawReport(on)
        }
    }

    private func resetStats() { lateMax = 0; writeMax = 0; writeTotal = 0; writeCount = 0 }

    private func reportStats(_ label: String) {
        guard writeCount > 0 else { return }
        let avg = writeTotal / Double(writeCount)
        logger?(String(format: "%@ timing (%@): steps fired up to %.0f ms late; write avg %.1f ms, max %.0f ms (%d writes)",
                       label, method.label, lateMax, avg, writeMax, writeCount))
    }

    /// Before an animation: with `rawInhibit`, tell the driver to keep its hands
    /// off the LED so our reports are not overridden.
    private func beginTakeover() {
        guard method == .rawInhibit, let service = keyboardService() else { return }
        _ = IOHIDServiceClientSetProperty(service, Self.capsLockLEDKey as CFString, "inhibit" as CFString)
    }

    /// Hand the LED back to macOS.
    private func restore() {
        let caps = CGEventSource.flagsState(.combinedSessionState).contains(.maskAlphaShift)
        DispatchQueue.main.async { self.ledOn = caps }
        switch method {
        case .driver, .rawInhibit:
            if let service = keyboardService() {
                _ = IOHIDServiceClientSetProperty(service, Self.capsLockLEDKey as CFString, "auto" as CFString)
            }
            if method == .rawInhibit { writeRawReport(caps) }
        case .raw:
            writeRawReport(caps)
        }
    }

    // MARK: - LED write

    private func setLED(_ on: Bool) {
        DispatchQueue.main.async { self.ledOn = on }
        let t0 = DispatchTime.now()
        switch method {
        case .driver:
            if let service = keyboardService() {
                let ok = IOHIDServiceClientSetProperty(service, Self.capsLockLEDKey as CFString, (on ? "on" : "off") as CFString)
                if ok == 0, !reportedFailure { reportedFailure = true; logger?("Caps Lock LED: driver refused the property") }
            } else if !reportedFailure {
                reportedFailure = true; logger?("Caps Lock LED: keyboard service not found")
            }
        case .raw, .rawInhibit:
            writeRawReport(on)
        }
        let ms = Double(DispatchTime.now().uptimeNanoseconds - t0.uptimeNanoseconds) / 1_000_000
        writeMax = max(writeMax, ms); writeTotal += ms; writeCount += 1
    }

    // MARK: - Path 1: the keyboard's event-driver service (no Input Monitoring needed)

    private static let capsLockLEDKey = "HIDCapsLockLED"
    private var eventClient: CFTypeRef?
    private var cachedService: CFTypeRef?

    private func keyboardService() -> CFTypeRef? {
        if let s = cachedService { return s }
        if eventClient == nil {
            // Passive client: property access only, no event delivery.
            eventClient = IOHIDEventSystemClientCreateWithType(kCFAllocatorDefault, 2, nil)?.takeRetainedValue()
        }
        guard let client = eventClient else { return nil }
        let matching: [String: Any] = [
            kIOHIDVendorIDKey as String: 0x4C,
            kIOHIDPrimaryUsagePageKey as String: 0x01,
            kIOHIDPrimaryUsageKey as String: 0x06,
            kIOHIDTransportKey as String: "Bluetooth",
        ]
        IOHIDEventSystemClientSetMatching(client, matching as CFDictionary)
        guard let services = IOHIDEventSystemClientCopyServices(client)?.takeRetainedValue() as? [CFTypeRef] else { return nil }
        let service = services.first { s in
            let product = IOHIDServiceClientCopyProperty(s, kIOHIDProductKey as CFString)?.takeRetainedValue() as? String ?? ""
            return product.contains("Magic Keyboard")
        } ?? services.first
        cachedService = service
        return service
    }

    /// Forgets cached handles, e.g. after the keyboard reconnects.
    func invalidate() {
        queue.async {
            self.cachedService = nil
            if let d = self.cachedDevice { IOHIDDeviceClose(d, IOOptionBits(kIOHIDOptionsTypeNone)) }
            self.cachedDevice = nil
            self.reportedFailure = false
        }
    }

    // MARK: - Path 2: raw HID output report (needs Input Monitoring)

    private var cachedDevice: IOHIDDevice?
    private var reportedFailure = false

    private func keyboardDevice() -> IOHIDDevice? {
        if let d = cachedDevice { return d }
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        let matching: [String: Any] = [
            kIOHIDVendorIDKey as String: 0x4C,
            kIOHIDPrimaryUsagePageKey as String: 0x01,
            kIOHIDPrimaryUsageKey as String: 0x06,
            kIOHIDTransportKey as String: "Bluetooth",
        ]
        IOHIDManagerSetDeviceMatching(manager, matching as CFDictionary)
        guard let set = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice> else { return nil }
        let device = set.first { d in
            let product = IOHIDDeviceGetProperty(d, kIOHIDProductKey as CFString) as? String ?? ""
            return product.contains("Magic Keyboard")
        } ?? set.first
        guard let device else { return nil }
        ensureAccess()
        let r = IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeNone))
        guard r == kIOReturnSuccess else {
            if !reportedFailure {
                reportedFailure = true
                logger?("Caps Lock LED: could not open keyboard (\(Self.hex(r))). " + Self.accessHint())
            }
            return nil
        }
        cachedDevice = device
        return device
    }

    private func writeRawReport(_ on: Bool) {
        guard let device = keyboardDevice() else { return }
        // Numbered report: the buffer carries the report ID itself, then the LED bits.
        var report: [UInt8] = [0x01, on ? 0x02 : 0x00]
        let r = IOHIDDeviceSetReport(device, kIOHIDReportTypeOutput, 1, &report, report.count)
        if r != kIOReturnSuccess {
            cachedDevice = nil
            if !reportedFailure {
                reportedFailure = true
                logger?("Caps Lock LED: write failed (\(Self.hex(r)))")
            }
        }
    }

    private func ensureAccess() {
        if IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) != kIOHIDAccessTypeGranted {
            _ = IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
        }
    }

    // MARK: - Input Monitoring permission (for the UI)

    /// True when macOS lets this app open the keyboard for the LED.
    static var inputMonitoringGranted: Bool {
        IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted
    }

    /// Triggers the system prompt if macOS has not decided yet, and opens the
    /// Input Monitoring pane so an earlier "deny" can be flipped.
    static func requestInputMonitoring() {
        _ = IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent") {
            NSWorkspace.shared.open(url)
        }
    }

    /// macOS applies a fresh grant only to a new process.
    static func relaunch() {
        let config = NSWorkspace.OpenConfiguration()
        config.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: config) { _, _ in
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
    }

    private static func accessHint() -> String {
        switch IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) {
        case kIOHIDAccessTypeGranted:
            return "Input Monitoring is granted; if it was granted just now, quit and reopen Magic Handoff."
        case kIOHIDAccessTypeDenied:
            return "Turn on Magic Handoff under System Settings → Privacy & Security → Input Monitoring, then quit and reopen the app."
        default:
            return "Allow Input Monitoring when macOS asks, then quit and reopen the app."
        }
    }

    private static func hex(_ r: IOReturn) -> String { String(format: "0x%08x", UInt32(bitPattern: r)) }

    // MARK: - Diagnostics (Settings → Test)

    func diagnose(completion: @escaping (Bool) -> Void) {
        queue.async {
            self.cachedService = nil
            self.cachedDevice = nil
            self.reportedFailure = false
            self.logger?("Caps Lock LED test: method = \(self.method.label)")
            var serviceOK = false
            if let service = self.keyboardService() {
                let name = IOHIDServiceClientCopyProperty(service, kIOHIDProductKey as CFString)?.takeRetainedValue() as? String ?? "?"
                let ok = IOHIDServiceClientSetProperty(service, Self.capsLockLEDKey as CFString, "auto" as CFString)
                serviceOK = ok != 0
                self.logger?("Caps Lock LED test: driver service \(name), property \(serviceOK ? "accepted" : "refused")")
            } else {
                self.logger?("Caps Lock LED test: driver service not found")
            }
            if self.method == .driver {
                DispatchQueue.main.async { completion(serviceOK) }
                return
            }
            let access = IOHIDCheckAccess(kIOHIDRequestTypeListenEvent)
            let accessText = access == kIOHIDAccessTypeGranted ? "granted" : access == kIOHIDAccessTypeDenied ? "denied" : "not determined"
            self.logger?("Caps Lock LED test: Input Monitoring \(accessText)")
            guard let device = self.keyboardDevice() else {
                self.logger?("Caps Lock LED test: no Bluetooth Magic Keyboard could be opened. " + Self.accessHint())
                DispatchQueue.main.async { completion(false) }
                return
            }
            let name = IOHIDDeviceGetProperty(device, kIOHIDProductKey as CFString) as? String ?? "?"
            var report: [UInt8] = [0x01, 0x00]
            let r = IOHIDDeviceSetReport(device, kIOHIDReportTypeOutput, 1, &report, report.count)
            self.logger?("Caps Lock LED test: raw report to \(name) → \(Self.hex(r))")
            DispatchQueue.main.async { completion(r == kIOReturnSuccess) }
        }
    }
}

// MARK: - IOHIDEventSystemClient (exported by IOKit, not in the public headers)

@_silgen_name("IOHIDEventSystemClientCreateWithType")
private func IOHIDEventSystemClientCreateWithType(_ allocator: CFAllocator?, _ type: Int32, _ attributes: CFDictionary?) -> Unmanaged<CFTypeRef>?

@_silgen_name("IOHIDEventSystemClientSetMatching")
private func IOHIDEventSystemClientSetMatching(_ client: CFTypeRef, _ matching: CFDictionary)

@_silgen_name("IOHIDEventSystemClientCopyServices")
private func IOHIDEventSystemClientCopyServices(_ client: CFTypeRef) -> Unmanaged<CFArray>?

@_silgen_name("IOHIDServiceClientSetProperty")
private func IOHIDServiceClientSetProperty(_ service: CFTypeRef, _ key: CFString, _ value: CFTypeRef) -> UInt8

@_silgen_name("IOHIDServiceClientCopyProperty")
private func IOHIDServiceClientCopyProperty(_ service: CFTypeRef, _ key: CFString) -> Unmanaged<CFTypeRef>?
