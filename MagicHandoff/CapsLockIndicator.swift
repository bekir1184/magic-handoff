import Foundation
import IOKit.hid
import CoreGraphics

/// Uses the Magic Keyboard's Caps Lock LED as a status light.
///
/// The keyboard's only host-controllable light is the Caps Lock LED (HID output
/// report 1, LED usage page bit 2). Writing the report lights the LED without
/// changing the Caps Lock state; when the animation ends the LED is put back to
/// whatever Caps Lock really is.
final class CapsLockIndicator {
    private let queue = DispatchQueue(label: "com.bekirersever.magichandoff.capslock")
    private var generation = 0          // bumping it cancels the running animation
    private var loadingActive = false
    var logger: ((String) -> Void)?
    var enabled = true

    // MARK: - Public

    /// Repeating double pulse until `stopLoading()` or `playConnected()`.
    func startLoading() {
        guard enabled else { return }
        queue.async {
            guard !self.loadingActive else { return }
            self.loadingActive = true
            self.generation += 1
            self.loop(generation: self.generation)
        }
    }

    func stopLoading() {
        queue.async {
            self.loadingActive = false
            self.generation += 1
            self.restore()
        }
    }

    /// Three bounces that fade out, then back to the real Caps Lock state.
    func playConnected() {
        guard enabled else { return }
        queue.async {
            self.loadingActive = false
            self.generation += 1
            let g = self.generation
            let pattern: [(on: Bool, ms: Int)] = [
                (true, 90), (false, 90),
                (true, 90), (false, 180),
                (true, 90), (false, 360),
                (true, 140), (false, 0),
            ]
            self.play(pattern, generation: g) { self.restore() }
        }
    }

    /// One short blink, e.g. when handing the keyboard away.
    func playGoodbye() {
        guard enabled else { return }
        queue.async {
            self.generation += 1
            let g = self.generation
            self.play([(true, 120), (false, 0)], generation: g) { self.restore() }
        }
    }

    // MARK: - Animation engine (runs on `queue`)

    private func loop(generation g: Int) {
        guard g == generation, loadingActive else { return }
        play([(true, 110), (false, 110), (true, 110), (false, 620)], generation: g) {
            self.loop(generation: g)
        }
    }

    private func play(_ steps: [(on: Bool, ms: Int)], generation g: Int, done: @escaping () -> Void) {
        var remaining = steps
        func next() {
            guard g == self.generation else { return }
            guard let step = remaining.first else { done(); return }
            remaining.removeFirst()
            self.setLED(step.on)
            self.queue.asyncAfter(deadline: .now() + .milliseconds(step.ms)) { next() }
        }
        next()
    }

    private func restore() {
        let caps = CGEventSource.flagsState(.combinedSessionState).contains(.maskAlphaShift)
        setLED(caps)
    }

    // MARK: - HID

    private var cachedDevice: IOHIDDevice?
    private var reportedFailure = false

    private func keyboardDevice() -> IOHIDDevice? {
        if let d = cachedDevice { return d }
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        let matching: [String: Any] = [
            kIOHIDVendorIDKey as String: 0x4C,
            kIOHIDPrimaryUsagePageKey as String: 0x01,   // Generic Desktop
            kIOHIDPrimaryUsageKey as String: 0x06,       // Keyboard
            kIOHIDTransportKey as String: "Bluetooth",
        ]
        IOHIDManagerSetDeviceMatching(manager, matching as CFDictionary)
        guard let set = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice> else { return nil }
        // Prefer the bluetoothd-backed user device; any match will route to the keyboard.
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

    /// Opening a keyboard needs the Input Monitoring permission. Ask for it the
    /// first time; macOS applies a fresh grant only after the app is relaunched.
    private func ensureAccess() {
        if IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) != kIOHIDAccessTypeGranted {
            _ = IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
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

    /// Step-by-step check written to the log, for the Test button.
    func diagnose(completion: @escaping (Bool) -> Void) {
        queue.async {
            let access = IOHIDCheckAccess(kIOHIDRequestTypeListenEvent)
            let accessText = access == kIOHIDAccessTypeGranted ? "granted" : access == kIOHIDAccessTypeDenied ? "denied" : "not determined"
            self.logger?("Caps Lock LED test: Input Monitoring \(accessText)")
            self.reportedFailure = false
            self.cachedDevice = nil
            guard let device = self.keyboardDevice() else {
                self.logger?("Caps Lock LED test: no Bluetooth Magic Keyboard could be opened. " + Self.accessHint())
                DispatchQueue.main.async { completion(false) }
                return
            }
            let name = IOHIDDeviceGetProperty(device, kIOHIDProductKey as CFString) as? String ?? "?"
            var report: [UInt8] = [0x01, 0x02]
            let r = IOHIDDeviceSetReport(device, kIOHIDReportTypeOutput, 1, &report, report.count)
            self.logger?("Caps Lock LED test: \(name) opened, LED on [01 02] → \(Self.hex(r))")
            DispatchQueue.main.async { completion(r == kIOReturnSuccess) }
        }
    }

    /// Forgets the opened device, e.g. after the keyboard disconnects.
    func invalidate() {
        queue.async {
            if let d = self.cachedDevice { IOHIDDeviceClose(d, IOOptionBits(kIOHIDOptionsTypeNone)) }
            self.cachedDevice = nil
            self.reportedFailure = false
        }
    }

    private func setLED(_ on: Bool) {
        guard let device = keyboardDevice() else { return }
        // Numbered report: the buffer carries the report ID itself, then the LED
        // bits (bit 1 = Caps Lock). Without the ID byte the keyboard ignores it.
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
}
