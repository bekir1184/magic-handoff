import Foundation
import IOBluetooth
import CoreBluetooth
import AppKit

/// Bluetooth layer: release and take Magic peripherals on this Mac.
///
/// Mechanism:
///  - Release: the bond is removed through IOBluetoothDevice's private `-remove`
///    selector (same as "Forget This Device" in System Settings). If the selector
///    is unavailable, `closeConnection()` only drops the session.
///  - Take: if the device is still bonded to this Mac, `openConnection()` is
///    tried first; otherwise a fresh pairing is started with `IOBluetoothDevicePair`.
///
/// Every IOBluetooth call is synchronous IPC with bluetoothd, so all of them run
/// on a dedicated serial queue; UI updates hop back to the main queue.
final class BluetoothController: NSObject, ObservableObject {
    @Published private(set) var peripherals: [Peripheral] = []
    @Published private(set) var log: [String] = []
    @Published private(set) var bluetoothAuthorized = true
    @Published private(set) var isScanning = false

    var anyConnected: Bool { peripherals.contains { $0.state == .connected } }

    private let queue = DispatchQueue(label: "com.bekirersever.magichandoff.bluetooth", qos: .userInitiated)
    private var pendingPairs: [String: IOBluetoothDevicePair] = [:]
    private var pairTimeouts: [String: DispatchWorkItem] = [:]
    private var refreshTimer: Timer?
    private var central: CBCentralManager?
    private var inquiry: IOBluetoothDeviceInquiry?
    private var connectNotification: IOBluetoothUserNotification?
    private var disconnectNotifications: [String: IOBluetoothUserNotification] = [:]

    private enum Op { case release, take }
    /// Completion handlers waiting for a release/take to reach a terminal state.
    private var waiters: [String: [(op: Op, callback: (Bool) -> Void)]] = [:]
    /// When the current operation on a device started, for timing in the log.
    private var opStarted: [String: Date] = [:]
    /// Devices we let go of on purpose while keeping the bond, with the time.
    /// If one reconnects to us inside the handoff window, we drop it again so
    /// the other Mac can win.
    private var releasedOnPurpose: [String: Date] = [:]

    /// Whether to keep the pairing when releasing (fast switching). Set by the app.
    var keepBonds = true

    /// Devices this Mac told bluetoothd to ignore while the other Mac holds them
    /// (IOBluetoothIgnoreHIDDevice). Persisted so a relaunch can undo it.
    private var ignoredByUs: Set<String> = [] {
        didSet { UserDefaults.standard.set(Array(ignoredByUs), forKey: Self.ignoredKey) }
    }
    private static let ignoredKey = "ignoredPeripherals"
    /// When each ignore was set, to keep housekeeping from lifting a fresh one.
    private var ignoredAt: [String: Date] = [:]

    private enum Tuning {
        /// `-remove` completes asynchronously inside bluetoothd; pairing right
        /// after it on the same Mac races the unbond and fails.
        static let unbondSettle: TimeInterval = 0.5
        /// DevicePair.start() pages forever against a device held by the other
        /// Mac, so we cap it.
        static let pairTimeout: TimeInterval = 45
        /// After pairing reports success, how long to wait for the link before
        /// nudging it with openConnection.
        static let postPairGrace: TimeInterval = 3
        /// How long after a keep-bond release a device bouncing back to us is
        /// pushed away again.
        static let bounceWindow: TimeInterval = 20
        /// Keep-bond take: how many times to retry a plain connect before giving
        /// up on the bond and pairing from scratch.
        static let connectAttempts = 4
        static let connectRetryGap: TimeInterval = 0.8
        /// Host-initiated connect right after pairing, before the device reconnects by itself.
        static let postPairConnectAttempts = 3
        static let postPairRetryGap: TimeInterval = 0.3
        /// Let bluetoothd finish deleting the record before the ignore is set on it.
        static let ignoreAfterRemoveDelay: TimeInterval = 0.3
        /// HCI page timeout for the bonded-connect probe, in 0.625 ms slots (≈5 s).
        static let probePageTimeout: BluetoothHCIPageTimeout = 8000
        static let refreshInterval: TimeInterval = 2
        static let inquiryLength: UInt8 = 8
    }

    override init() {
        super.init()
        // Waking CoreBluetooth makes the TCC Bluetooth prompt appear properly on
        // first launch; IOBluetooth goes through the same coordinator.
        central = CBCentralManager(delegate: self, queue: nil)
        loadKnown()
        ignoredByUs = Set(UserDefaults.standard.stringArray(forKey: Self.ignoredKey) ?? [])
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            self?.unignoreAll()
        }
        connectNotification = IOBluetoothDevice.register(
            forConnectNotifications: self, selector: #selector(deviceDidConnect(_:device:)))
        refresh()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: Tuning.refreshInterval, repeats: true) { [weak self] _ in
            self?.refresh()
        }
    }

    // MARK: - Listing

    func refresh() {
        queue.async { [weak self] in
            guard let self else { return }
            let devices = (IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice]) ?? []
            let snapshot: [LiveDevice] = devices.compactMap { d in
                guard let addr = d.addressString else { return nil }
                let kind = Self.kind(of: d)
                guard kind != .other else { return nil }   // HID input devices only
                return LiveDevice(id: addr, name: d.name ?? addr, kind: kind, paired: d.isPaired(), connected: d.isConnected())
            }
            DispatchQueue.main.async {
                self.merge(snapshot)
            }
        }
    }

    private struct LiveDevice {
        let id: String, name: String, kind: Peripheral.Kind, paired: Bool, connected: Bool
    }

    private func merge(_ snapshot: [LiveDevice]) {
        // A device whose bond was removed drops out of pairedDevices(); keep every
        // device we have ever seen so its "Take" button stays available.
        for s in snapshot { known[s.id] = KnownDevice(name: s.name, kind: s.kind) }
        saveKnown()

        var next: [Peripheral] = []
        for (id, k) in known {
            let live = snapshot.first { $0.id == id }
            if var existing = peripherals.first(where: { $0.id == id }) {
                existing.name = live?.name ?? k.name
                existing.isPaired = live?.paired ?? false
                if !existing.state.isBusy {
                    if live?.connected == true {
                        existing.state = .connected
                    } else if !existing.state.isFailure {
                        existing.state = .disconnected
                    }
                }
                next.append(existing)
            } else {
                next.append(Peripheral(id: id, name: live?.name ?? k.name, kind: k.kind,
                                       isPaired: live?.paired ?? false,
                                       state: live?.connected == true ? .connected : .disconnected))
            }
        }
        next.sort { $0.name < $1.name }
        if next != peripherals { peripherals = next }

        // Housekeeping for relaunches: something we ignored long ago is connected
        // here anyway, so lift it. A fresh ignore is left alone — right after a
        // release the device still reads as connected for a moment.
        for s in snapshot where s.connected && ignoredByUs.contains(s.id) {
            if let at = ignoredAt[s.id], Date().timeIntervalSince(at) < 30 { continue }
            if let d = IOBluetoothDevice(addressString: s.id) { queue.async { self.unignore(d, id: s.id) } }
        }
    }

    private static func kind(of device: IOBluetoothDevice) -> Peripheral.Kind {
        // Class of Device: major = peripheral (0x05); minor bits 6-7: 01 keyboard, 10 pointing.
        let cod = device.classOfDevice
        let major = (cod >> 8) & 0x1F
        guard major == 0x05 else { return .other }
        let minor = (cod >> 2) & 0x3F
        let isKeyboard = (minor & 0x10) != 0
        let isPointing = (minor & 0x20) != 0
        let name = (device.name ?? "").lowercased()
        if isKeyboard { return .keyboard }
        if isPointing { return name.contains("trackpad") ? .trackpad : .mouse }
        return .other
    }

    // MARK: - Nearby scan

    /// Classic Bluetooth inquiry. A Magic device whose bond was removed, or one
    /// currently paired to the other Mac, never shows up in pairedDevices();
    /// this is how it gets into the list.
    func scanNearby() {
        guard !isScanning else { return }
        guard let inq = IOBluetoothDeviceInquiry(delegate: self) else {
            append("Could not start scan"); return
        }
        inq.inquiryLength = Tuning.inquiryLength
        inq.updateNewDeviceNames = true
        inquiry = inq
        let r = inq.start()
        if r == kIOReturnSuccess {
            isScanning = true
            append("Scanning nearby devices (\(Tuning.inquiryLength)s)… keep the device on and discoverable")
        } else {
            append("Could not start scan (\(r))")
        }
    }

    /// Removes the device from the persistent list (does not touch the bond).
    func forget(_ id: String) {
        known.removeValue(forKey: id)
        saveKnown()
        peripherals.removeAll { $0.id == id }
    }

    // MARK: - Persistent device list

    private struct KnownDevice: Codable, Equatable {
        var name: String
        var kindRaw: String
        var kind: Peripheral.Kind { Peripheral.Kind(rawValue: kindRaw) ?? .other }
        init(name: String, kind: Peripheral.Kind) { self.name = name; self.kindRaw = kind.rawValue }
    }

    private var known: [String: KnownDevice] = [:]
    private static let knownKey = "knownPeripherals"

    private func loadKnown() {
        guard let data = UserDefaults.standard.data(forKey: Self.knownKey),
              let decoded = try? JSONDecoder().decode([String: KnownDevice].self, from: data) else { return }
        known = decoded
    }

    private func saveKnown() {
        if let data = try? JSONEncoder().encode(known) {
            UserDefaults.standard.set(data, forKey: Self.knownKey)
        }
    }

    // MARK: - Interface for the handoff coordinator

    func appendLog(_ line: String) { append(line) }

    func deviceInfo(_ id: String) -> DeviceInfo? {
        peripherals.first { $0.id == id }.map {
            DeviceInfo(id: $0.id, name: $0.name, kind: $0.kind.rawValue, connected: $0.state == .connected)
        }
    }

    func deviceInfos() -> [DeviceInfo] {
        peripherals.compactMap { deviceInfo($0.id) }
    }

    /// Adds a device announced by the other Mac so it can be taken here. Main queue only.
    func ensureKnown(_ info: DeviceInfo) {
        guard known[info.id] == nil else { return }
        let kind = Peripheral.Kind(rawValue: info.kind) ?? .other
        known[info.id] = KnownDevice(name: info.name, kind: kind)
        saveKnown()
        peripherals.append(Peripheral(id: info.id, name: info.name, kind: kind, isPaired: false, state: .disconnected))
        peripherals.sort { $0.name < $1.name }
    }

    // MARK: - Ignore list (the "Ignore this device" checkbox, programmatically)

    /// IOBluetoothDeviceRef is toll-free bridged with IOBluetoothDevice.
    private static func ref(_ device: IOBluetoothDevice) -> IOBluetoothDeviceRef {
        unsafeBitCast(device, to: IOBluetoothDeviceRef.self)
    }

    /// Tells bluetoothd to refuse this HID device when it tries to reconnect on
    /// its own. The bond is untouched. Runs on the Bluetooth queue.
    private func ignore(_ device: IOBluetoothDevice, id: String) {
        IOBluetoothIgnoreHIDDevice(Self.ref(device))
        DispatchQueue.main.async { self.ignoredByUs.insert(id); self.ignoredAt[id] = Date() }
    }

    /// Runs on the Bluetooth queue.
    private func unignore(_ device: IOBluetoothDevice, id: String) {
        IOBluetoothRemoveIgnoredHIDDevice(Self.ref(device))
        DispatchQueue.main.async { self.ignoredByUs.remove(id); self.ignoredAt[id] = nil }
    }

    /// Runs on the Bluetooth queue.
    private func liftIgnoreIfNeeded(_ device: IOBluetoothDevice, id: String) {
        guard ignoredByUs.contains(id) else { return }
        unignore(device, id: id)
        append("\(device.name ?? id): no longer ignored")
    }

    private func unignoreAll() {
        for id in ignoredByUs {
            if let d = IOBluetoothDevice(addressString: id) {
                IOBluetoothRemoveIgnoredHIDDevice(Self.ref(d))
            }
        }
        ignoredByUs.removeAll()
    }

    // MARK: - Release

    func release(_ id: String, completion: ((Bool) -> Void)? = nil) {
        if let completion { addWaiter(id, .release, completion) }
        opStarted[id] = Date()
        setState(.releasing, for: id)
        let keep = keepBonds
        queue.async { [weak self] in
            guard let self else { return }
            guard let device = IOBluetoothDevice(addressString: id) else {
                self.setState(.failed("device not found"), for: id); return
            }
            let name = device.name ?? id

            if keep {
                // Fast switching: drop the link, keep the pairing. The device keeps
                // our key too, so coming back is a plain connect with no dialog.
                DispatchQueue.main.async { self.releasedOnPurpose[id] = Date() }
                if !device.isConnected() {
                    self.ignore(device, id: id)
                    self.append("\(name): already disconnected; ignoring reconnects")
                    self.setState(.disconnected, for: id); return
                }
                // Refuse the device's own reconnect attempts first, then drop the link.
                self.ignore(device, id: id)
                let r = device.closeConnection()
                if r == kIOReturnSuccess {
                    self.append("\(name): ignored + link closed, pairing kept (paired=\(device.isPaired())) \(self.elapsed(id))")
                    self.setState(.disconnected, for: id)
                } else {
                    self.append("\(name): closeConnection failed (\(r)); removing bond instead")
                    self.removeBond(device, id: id, name: name)
                }
                return
            }

            self.removeBond(device, id: id, name: name)
        }
    }

    /// Classic release: forget the device on this Mac. Runs on the Bluetooth queue.
    ///
    /// Once unbonded the device tries to reconnect to us; without an ignore that
    /// raises macOS's "Connection Request" dialog and blocks the other Mac's
    /// pairing. `-remove` deletes the whole device record, which appears to take
    /// the ignore flag with it, so the ignore is applied *after* the removal has
    /// had a moment to land in bluetoothd.
    private func removeBond(_ device: IOBluetoothDevice, id: String, name: String) {
        DispatchQueue.main.async { self.releasedOnPurpose[id] = nil }
        if device.responds(to: Selector(("remove"))) {
            device.perform(Selector(("remove")))
            append("\(name): bond removed \(elapsed(id)); ignoring its reconnects")
            queue.asyncAfter(deadline: .now() + Tuning.ignoreAfterRemoveDelay) { [weak self] in
                guard let self, let again = IOBluetoothDevice(addressString: id) else { return }
                self.ignore(again, id: id)
                self.append("\(name): ignored (paired=\(again.isPaired()))")
            }
            setState(.disconnected, for: id)
        } else {
            ignore(device, id: id)
            let r = device.closeConnection()
            if r == kIOReturnSuccess {
                append("\(name): -remove unavailable, ignored + session closed \(elapsed(id))")
                setState(.disconnected, for: id)
            } else {
                append("\(name): closeConnection failed (\(r))")
                setState(.failed("release failed \(r)"), for: id)
            }
        }
    }

    // MARK: - Take

    /// - Parameter liftIgnoreFirst: normally the device stays on the ignore list
    ///   while we pair with it, so its own reconnect attempts are refused silently
    ///   instead of raising the "Connection Request" dialog; the ignore is lifted
    ///   once pairing succeeds. Pass `true` on a retry, in case the ignore was
    ///   what got in the way.
    func take(_ id: String, liftIgnoreFirst: Bool = false, completion: ((Bool) -> Void)? = nil) {
        if let completion { addWaiter(id, .take, completion) }
        opStarted[id] = Date()
        releasedOnPurpose[id] = nil
        setState(.taking("Connecting…"), for: id)
        let keep = keepBonds
        queue.async { [weak self] in
            guard let self else { return }
            guard let device = IOBluetoothDevice(addressString: id) else {
                self.setState(.failed("device not found"), for: id); return
            }
            let name = device.name ?? id

            if self.ignoredByUs.contains(id) {
                if liftIgnoreFirst {
                    self.unignore(device, id: id)
                    self.append("\(name): no longer ignored")
                } else {
                    self.append("\(name): pairing while still refusing its own reconnects")
                }
            }

            if device.isConnected() {
                self.append("\(name): already connected")
                self.setState(.connected, for: id); return
            }

            // 1) Still bonded to us: the cheap path is a direct connect. With fast
            //    switching the device may still be letting go of the other Mac, so
            //    retry a few times before deciding the bond is dead.
            if device.isPaired() {
                self.connectBonded(device, id: id, name: name,
                                   attemptsLeft: keep ? Tuning.connectAttempts : 1)
                return
            }

            // 2) No bond: pair from scratch.
            self.startPairing(id: id, name: name)
        }
    }

    /// Runs on the Bluetooth queue.
    private func connectBonded(_ device: IOBluetoothDevice, id: String, name: String, attemptsLeft: Int) {
        // The device may have connected to us on its own in the meantime.
        if device.isConnected() {
            self.liftIgnoreIfNeeded(device, id: id)
            self.append("\(name): connected \(self.elapsed(id))")
            self.watchDisconnect(of: device, id: id)
            self.setState(.connected, for: id); return
        }
        // Short page timeout: a dead bond should cost a few seconds, not 20.
        let r = device.openConnection(nil, withPageTimeout: Tuning.probePageTimeout, authenticationRequired: true)
        if device.isConnected() {
            self.liftIgnoreIfNeeded(device, id: id)
            self.append("\(name): connected via openConnection \(self.elapsed(id))")
            self.watchDisconnect(of: device, id: id)
            self.setState(.connected, for: id); return
        }
        if attemptsLeft > 1 {
            self.append("\(name): connect attempt failed (\(r)) \(self.elapsed(id)); retrying")
            self.queue.asyncAfter(deadline: .now() + Tuning.connectRetryGap) { [weak self] in
                guard let self, self.isStillTaking(id) else { return }
                self.connectBonded(device, id: id, name: name, attemptsLeft: attemptsLeft - 1)
            }
            return
        }
        self.append("\(name): openConnection failed (\(r)) \(self.elapsed(id)); bond is stale, removing it")
        if device.responds(to: Selector(("remove"))) {
            device.perform(Selector(("remove")))
        }
        self.queue.asyncAfter(deadline: .now() + Tuning.unbondSettle) {
            self.startPairing(id: id, name: name)
        }
    }

    private func isStillTaking(_ id: String) -> Bool {
        var taking = false
        DispatchQueue.main.sync {
            if case .taking = self.peripherals.first(where: { $0.id == id })?.state { taking = true }
        }
        return taking
    }

    private func startPairing(id: String, name: String) {
        guard let fresh = IOBluetoothDevice(addressString: id),
              let pair = IOBluetoothDevicePair(device: fresh) else {
            append("\(name): could not create IOBluetoothDevicePair")
            setState(.failed("could not start pairing"), for: id); return
        }
        pair.delegate = self
        DispatchQueue.main.async {
            self.pendingPairs[id]?.stop()
            self.pendingPairs[id] = pair
            self.armPairTimeout(id: id, name: name)
        }
        setState(.taking("Pairing…"), for: id)
        let r = pair.start()
        if r != kIOReturnSuccess {
            append("\(name): DevicePair.start failed (\(r))")
            DispatchQueue.main.async { self.clearPending(id) }
            setState(.failed("pairing \(r)"), for: id)
        } else {
            append("\(name): pairing started \(elapsed(id))")
        }
    }

    /// Runs on the Bluetooth queue.
    private func connectAfterPairing(id: String, name: String, attemptsLeft: Int) {
        guard let device = IOBluetoothDevice(addressString: id) else { return }
        if device.isConnected() {
            self.append("\(name): link up on its own \(self.elapsed(id))")
            self.setState(.connected, for: id); return
        }
        let r = device.openConnection(nil, withPageTimeout: Tuning.probePageTimeout, authenticationRequired: true)
        if device.isConnected() {
            self.append("\(name): connected via openConnection after pairing \(self.elapsed(id))")
            self.setState(.connected, for: id); return
        }
        if attemptsLeft > 1 {
            self.append("\(name): post-pair connect failed (\(r)) \(self.elapsed(id)); retrying")
            self.queue.asyncAfter(deadline: .now() + Tuning.postPairRetryGap) { [weak self] in
                guard let self, self.isStillTaking(id) else { return }
                self.connectAfterPairing(id: id, name: name, attemptsLeft: attemptsLeft - 1)
            }
            return
        }
        // Give up pushing; the connect notification still catches a device-initiated link.
        self.append("\(name): post-pair connect failed (\(r)) \(self.elapsed(id)); waiting for the device")
        self.setState(.taking("Waiting for link…"), for: id)
        self.queue.asyncAfter(deadline: .now() + Tuning.postPairGrace) {
            guard let again = IOBluetoothDevice(addressString: id) else { return }
            self.setState(again.isConnected() ? .connected : .failed("paired but no link"), for: id)
        }
    }

    private func armPairTimeout(id: String, name: String) {
        pairTimeouts[id]?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, let pair = self.pendingPairs[id] else { return }
            pair.stop()
            self.clearPending(id)
            self.append("\(name): pairing did not finish within \(Int(Tuning.pairTimeout))s")
            self.setState(.failed("timed out"), for: id)
        }
        pairTimeouts[id] = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Tuning.pairTimeout, execute: work)
    }

    private func clearPending(_ id: String) {
        pendingPairs.removeValue(forKey: id)
        pairTimeouts[id]?.cancel()
        pairTimeouts.removeValue(forKey: id)
    }

    // MARK: - Link notifications (instant state instead of polling)

    @objc private func deviceDidConnect(_ notification: IOBluetoothUserNotification, device: IOBluetoothDevice) {
        guard let id = device.addressString, known[id] != nil else { return }
        // Fast switching: we just let this device go so the other Mac can have it,
        // and it came straight back. Push it away again; the other Mac is paging.
        if let released = releasedOnPurpose[id], Date().timeIntervalSince(released) < Tuning.bounceWindow {
            let name = device.name ?? id
            append("\(name): came back after release; closing again so the other Mac can take it")
            queue.async { _ = device.closeConnection() }
            return
        }
        watchDisconnect(of: device, id: id)
        let wasTaking: Bool = {
            if case .taking = peripherals.first(where: { $0.id == id })?.state { return true }
            return false
        }()
        if wasTaking { append("\(device.name ?? id): link up \(elapsed(id))") }
        setState(.connected, for: id)
    }

    @objc private func deviceDidDisconnect(_ notification: IOBluetoothUserNotification, device: IOBluetoothDevice) {
        guard let id = device.addressString else { return }
        disconnectNotifications[id]?.unregister()
        disconnectNotifications[id] = nil
        // A disconnect during a take is part of the dance (unbond, re-pair); only
        // reflect it when nothing is in flight.
        if let p = peripherals.first(where: { $0.id == id }), !p.state.isBusy {
            setState(.disconnected, for: id)
        }
    }

    private func watchDisconnect(of device: IOBluetoothDevice, id: String) {
        DispatchQueue.main.async {
            guard self.disconnectNotifications[id] == nil else { return }
            self.disconnectNotifications[id] = device.register(
                forDisconnectNotification: self, selector: #selector(self.deviceDidDisconnect(_:device:)))
        }
    }

    // MARK: - Helpers

    private func setState(_ state: Peripheral.State, for id: String) {
        DispatchQueue.main.async {
            if let i = self.peripherals.firstIndex(where: { $0.id == id }) {
                self.peripherals[i].state = state
            }
            self.resolveWaiters(id: id, state: state)
        }
    }

    private func addWaiter(_ id: String, _ op: Op, _ callback: @escaping (Bool) -> Void) {
        waiters[id, default: []].append((op, callback))
    }

    /// Main queue only. Fires pending completions once the state is terminal.
    private func resolveWaiters(id: String, state: Peripheral.State) {
        guard !state.isBusy, let pending = waiters[id], !pending.isEmpty else { return }
        waiters[id] = nil
        for w in pending {
            switch (w.op, state) {
            case (.release, .disconnected): w.callback(true)
            case (.take, .connected): w.callback(true)
            default: w.callback(false)
            }
        }
    }

    private func elapsed(_ id: String) -> String {
        guard let start = opStarted[id] else { return "" }
        return String(format: "(%.2fs)", Date().timeIntervalSince(start))
    }

    private func append(_ line: String) {
        let stamp = DateFormatter.logTime.string(from: Date())
        DispatchQueue.main.async {
            self.log.append("\(stamp)  \(line)")
            if self.log.count > 300 { self.log.removeFirst(self.log.count - 300) }
        }
    }

    func clearLog() { log.removeAll() }
}

// MARK: - IOBluetoothDevicePair delegate (informal protocol)

extension BluetoothController {
    @objc func devicePairingStarted(_ sender: Any!) {}

    @objc func devicePairingConnecting(_ sender: Any!) {
        guard let pair = sender as? IOBluetoothDevicePair, let d = pair.device() else { return }
        setState(.taking("Establishing link…"), for: d.addressString ?? "")
    }

    @objc func devicePairingUserConfirmationRequest(_ sender: Any!, numericValue: BluetoothNumericValue) {
        // Magic devices pair "Just Works"; auto-accept if a confirmation is ever requested.
        guard let pair = sender as? IOBluetoothDevicePair else { return }
        append("\(pair.device()?.name ?? "?"): confirmation request (\(numericValue)) auto-accepted")
        pair.replyUserConfirmation(true)
    }

    @objc func devicePairingPINCodeRequest(_ sender: Any!) {
        guard let pair = sender as? IOBluetoothDevicePair else { return }
        append("\(pair.device()?.name ?? "?"): PIN requested (unexpected)")
    }

    @objc func devicePairingFinished(_ sender: Any!, error: IOReturn) {
        guard let pair = sender as? IOBluetoothDevicePair, let d = pair.device(), let id = d.addressString else { return }
        let name = d.name ?? id
        DispatchQueue.main.async {
            guard self.pendingPairs[id] === pair else { return }   // stale / cancelled attempt
            self.clearPending(id)
        }
        if error == kIOReturnSuccess {
            append("\(name): paired \(elapsed(id))")
            queue.async {
                guard let fresh = IOBluetoothDevice(addressString: id) else { return }
                // Bonded again: from now on its reconnects are welcome.
                self.liftIgnoreIfNeeded(fresh, id: id)
                self.watchDisconnect(of: fresh, id: id)
                if fresh.isConnected() {
                    self.append("\(name): connected \(self.elapsed(id))")
                    self.setState(.connected, for: id)
                    return
                }
                // The link dropped after pairing (the trackpad does this). Connect
                // from our side right now: if the device reconnects on its own
                // first, macOS greets it with the "Connection Request" dialog.
                self.setState(.taking("Connecting…"), for: id)
                self.connectAfterPairing(id: id, name: name, attemptsLeft: Tuning.postPairConnectAttempts)
            }
        } else if error == 4 {
            // HCI "page timeout": the device never answered. Magic devices ignore
            // other hosts while connected, so it is almost certainly on the other Mac.
            append("\(name): no answer (error 4) \(elapsed(id)). It is probably connected to your other Mac.")
            setState(.failed("held by another Mac?"), for: id)
        } else {
            append("\(name): pairing failed (\(error)) \(elapsed(id))")
            setState(.failed("pairing \(error)"), for: id)
        }
    }
}

// MARK: - IOBluetoothDeviceInquiry delegate

extension BluetoothController: IOBluetoothDeviceInquiryDelegate {
    func deviceInquiryDeviceFound(_ sender: IOBluetoothDeviceInquiry!, device: IOBluetoothDevice!) {
        guard let device, let addr = device.addressString else { return }
        let kind = Self.kind(of: device)
        guard kind != .other else { return }
        let name = device.name ?? addr
        if known[addr] == nil {
            known[addr] = KnownDevice(name: name, kind: kind)
            saveKnown()
            append("Found: \(name) (\(kind.rawValue))")
            refresh()
        }
    }

    func deviceInquiryComplete(_ sender: IOBluetoothDeviceInquiry!, error: IOReturn, aborted: Bool) {
        isScanning = false
        inquiry = nil
        append(aborted ? "Scan stopped" : "Scan finished")
    }
}

// MARK: - CoreBluetooth (authorization state only)

extension BluetoothController: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        let ok = central.state != .unauthorized
        DispatchQueue.main.async { self.bluetoothAuthorized = ok }
        if !ok { append("Bluetooth access denied: System Settings → Privacy & Security → Bluetooth") }
    }
}

private extension Peripheral.State {
    var isFailure: Bool { if case .failed = self { return true } else { return false } }
}

private extension DateFormatter {
    static let logTime: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()
}
