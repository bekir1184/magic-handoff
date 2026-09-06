import Foundation
import Combine
import IOKit.hid

/// Orchestrates a handoff between this Mac and the other one.
///
/// Send = ask the peer to start taking, then release here. The peer is already
///        paging the devices while we let go, so they connect the moment they are free.
/// Take = ask the peer to release and, without waiting for the answer, start
///        pairing here. Same overlap, from the other side.
///
/// Releases run together (they are instant); takes run one after another. Each stage is timed in the log.
final class HandoffCoordinator: ObservableObject {
    enum PeerStatus: Equatable { case none, offline, checking, online, codeMismatch }

    @Published private(set) var peerStatus: PeerStatus = .none
    @Published private(set) var peerDevices: [DeviceInfo] = []
    @Published private(set) var busy = false
    @Published var lastError: String?
    /// Hotkey number the other Mac reports, if any.
    @Published private(set) var peerHotkey: Int?

    let bluetooth: BluetoothController
    let settings: AppSettings
    let peers: PeerService

    private let sleepMonitor = SleepMonitor()
    let capsLock = CapsLockIndicator()
    private let hotkeys = HotkeyManager()
    /// How long the keyboard blinks on the sending Mac before it is released.
    private static let sendPreamble: TimeInterval = 0.6
    /// When the keyboard's searching animation started, so "connected" is not
    /// played before it has been visible for a moment.
    private var loadingStartedAt: Date?
    private static let minimumLoading: TimeInterval = 1.5
    /// How long to wait for macOS to create the HID device after the link is up.
    private static let hidReadyTimeout: TimeInterval = 5
    private var pingTimer: Timer?
    private var cancellables = Set<AnyCancellable>()

    init(bluetooth: BluetoothController, settings: AppSettings) {
        self.bluetooth = bluetooth
        self.settings = settings
        self.peers = PeerService(settings: settings)

        peers.logger = { [weak bluetooth] line in bluetooth?.appendLog(line) }
        capsLock.logger = { [weak bluetooth] line in bluetooth?.appendLog(line) }
        capsLock.enabled = settings.capsLockAnimations
        capsLock.method = CapsLockIndicator.Method(rawValue: settings.capsLockLEDMethod) ?? .rawInhibit
        settings.$capsLockLEDMethod
            .receive(on: DispatchQueue.main)
            .sink { [weak self] m in self?.capsLock.method = CapsLockIndicator.Method(rawValue: m) ?? .rawInhibit }
            .store(in: &cancellables)
        settings.$capsLockAnimations
            .receive(on: DispatchQueue.main)
            .sink { [weak self] on in self?.capsLock.enabled = on }
            .store(in: &cancellables)
        bluetooth.keepBonds = settings.keepBonds
        settings.$keepBonds
            .receive(on: DispatchQueue.main)
            .sink { [weak bluetooth] on in bluetooth?.keepBonds = on }
            .store(in: &cancellables)
        peers.requestHandler = { [weak self] message, reply in self?.handle(message, reply: reply) }

        peers.$peers
            .combineLatest(settings.$peerID)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _, _ in self?.peerListChanged() }
            .store(in: &cancellables)

        sleepMonitor.onWillSleep = { [weak self] done in self?.handleSleep(done: done) }
        sleepMonitor.onWake = { [weak self] in
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { self?.ping() }
            self?.handleWake()
        }

        pingTimer = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { [weak self] _ in self?.ping() }
        hotkeys.onHotkey = { [weak self] number in self?.handleHotkey(number) }
    }

    // MARK: - Hotkeys

    /// ⌘⇧N pressed on the keyboard, which is connected to this Mac. N is a Mac:
    /// this one → make sure everything is here; the other one → send everything there.
    private func handleHotkey(_ number: Int) {
        handedOffOnSleep = []
        guard isSetUp else { bluetooth.appendLog("⌘⇧\(number): set up the other Mac first"); return }
        guard !busy else { bluetooth.appendLog("⌘⇧\(number): a handoff is already running"); return }
        if number == settings.thisMacHotkey {
            let missing = bluetooth.peripherals.filter { $0.state != .connected && !$0.state.isBusy }
            if missing.isEmpty {
                bluetooth.appendLog("⌘⇧\(number): everything is already on this Mac")
                return
            }
            bluetooth.appendLog("⌘⇧\(number): bringing \(missing.count) device(s) here")
            takeAll()
        } else {
            guard bluetooth.anyConnected else {
                bluetooth.appendLog("⌘⇧\(number): nothing connected here to send")
                return
            }
            bluetooth.appendLog("⌘⇧\(number): sending everything to \(peerName)")
            sendAll(withPreamble: true)
        }
    }

    // MARK: - Peer selection & reachability

    var selectedPeer: Peer? {
        guard let id = settings.peerID else { return nil }
        return peers.peers.first { $0.id == id }
    }

    var peerName: String { settings.peerName ?? selectedPeer?.name ?? "other Mac" }

    /// The app is usable once both Macs share a code and the other Mac is chosen.
    var isSetUp: Bool { settings.hasPairingCode && settings.peerID != nil }

    /// Does that Mac advertise the same pairing code as this one?
    func usesSameCode(_ peer: Peer) -> Bool {
        guard let tag = peer.tag, let mine = settings.advertisedTag else { return false }
        return tag == mine
    }

    var matchingPeers: [Peer] { peers.peers.filter { usesSameCode($0) } }

    func selectPeer(_ peer: Peer?) {
        settings.peerID = peer?.id
        settings.peerName = peer?.name
        peerDevices = []
    }

    private func peerListChanged() {
        // First run: the moment exactly one Mac with the same code shows up, use it.
        if settings.peerID == nil, matchingPeers.count == 1, let only = matchingPeers.first {
            bluetooth.appendLog("Found \(only.name) with the same code; connected")
            selectPeer(only)
            return
        }
        guard settings.peerID != nil else { peerStatus = .none; return }
        guard let peer = selectedPeer else { peerStatus = .offline; return }
        if !usesSameCode(peer) { peerStatus = .codeMismatch; return }
        ping()
    }

    func ping() {
        guard let peer = selectedPeer else {
            peerStatus = settings.peerID == nil ? .none : .offline
            return
        }
        guard usesSameCode(peer) else { peerStatus = .codeMismatch; return }
        if peerStatus != .online { peerStatus = .checking }
        peers.request(Message(type: "ping"), to: peer, timeout: 6) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let reply):
                self.peerStatus = .online
                self.peerDevices = reply.devices ?? []
                self.peerHotkey = reply.hotkey
                if let h = reply.hotkey, h == self.settings.thisMacHotkey {
                    self.lastError = "Both Macs use ⌘⇧\(h). Give one of them the other number in Settings."
                } else if self.lastError?.hasPrefix("Both Macs use") == true {
                    self.lastError = nil
                }
                if let name = reply.fromName, name != self.settings.peerName { self.settings.peerName = name }
            case .failure(let error):
                self.peerStatus = .offline
                self.bluetooth.appendLog("\(peer.name) unreachable: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Send (this Mac → other Mac)

    func send(_ ids: [String], withPreamble: Bool = false, completion: ((Bool) -> Void)? = nil) {
        let infos = ids.compactMap { bluetooth.deviceInfo($0) }
        guard !infos.isEmpty else { completion?(true); return }
        guard let peer = selectedPeer, peerStatus == .online else {
            fail("\(peerName) is not reachable right now; nothing was released")
            completion?(false); return
        }
        busy = true
        lastError = nil
        let started = Date()
        let hasKeyboard = infos.contains { $0.kind == Peripheral.Kind.keyboard.rawValue }

        let release = { [weak self] in
            guard let self else { return }
            // Release first (it is near-instant), then tell the peer. A pairing attempt
            // that starts while the device is still linked here fails with "no connection".
            self.releaseAll(infos.map(\.id)) { results in
                self.bluetooth.appendLog("Released \(infos.count) device(s) \(Self.since(started)); telling \(peer.name)")
                self.peers.request(Message(type: "take", devices: infos), to: peer, timeout: 8) { result in
                    self.busy = false
                    switch result {
                    case .success:
                        self.bluetooth.appendLog("\(peer.name) is taking them \(Self.since(started))")
                        completion?(results.values.allSatisfy { $0 })
                    case .failure(let error):
                        self.fail("Released, but \(peer.name) could not be reached (\(error.localizedDescription)). Use Take to get the devices back.")
                        completion?(false)
                    }
                }
            }
        }

        _ = withPreamble; _ = hasKeyboard
        release()
    }

    func sendAll(withPreamble: Bool = false, completion: ((Bool) -> Void)? = nil) {
        send(bluetooth.peripherals.filter { $0.state == .connected }.map(\.id), withPreamble: withPreamble, completion: completion)
    }

    // MARK: - Take (other Mac → this Mac)

    func take(_ ids: [String]) {
        let infos = ids.compactMap { bluetooth.deviceInfo($0) }
        guard !infos.isEmpty else { return }
        busy = true
        lastError = nil
        let started = Date()

        // 1) Ask the peer to let go and wait for its answer: pairing a device that
        //    is still linked to the other Mac fails with "no connection" (error 2).
        //    If the peer is not around, go ahead anyway — nothing else can free it.
        let proceed: (Bool) -> Void = { [weak self] peerReleased in
            guard let self else { return }
            let settle: TimeInterval = peerReleased ? Self.postReleaseSettle : 0
            DispatchQueue.main.asyncAfter(deadline: .now() + settle) {
                self.takeWithRetry(infos.map(\.id), started: started, label: "Took", freshlyReleased: peerReleased)
            }
        }
        guard let peer = selectedPeer, peerStatus != .offline else { proceed(false); return }
        peers.request(Message(type: "release", devices: infos), to: peer, timeout: 8) { [weak self] result in
            switch result {
            case .success:
                self?.bluetooth.appendLog("\(peer.name) released \(Self.since(started))")
                proceed(true)
            case .failure(let error):
                self?.bluetooth.appendLog("\(peer.name) did not answer (\(error.localizedDescription)); trying anyway")
                proceed(false)
            }
        }
    }

    /// Give the device a moment to notice the unbond and enter pairing mode.
    private static let postReleaseSettle: TimeInterval = 0.4
    /// Pause before the automatic second attempt.
    private static let retryDelay: TimeInterval = 1.5

    private func takeWithRetry(_ ids: [String], started: Date, label: String, freshlyReleased: Bool = false) {
        loadingStartedAt = nil
        let ordered = keyboardFirst(ids)
        takeAll(ordered, freshlyReleased: freshlyReleased) { [weak self] results in
            guard let self else { return }
            let failed = results.filter { !$0.value }.map(\.key)
            if failed.isEmpty {
                self.busy = false
                self.playConnectedAfterMinimumLoading()
                self.bluetooth.appendLog("\(label) \(ids.count) device(s) \(Self.since(started))")
                return
            }
            self.bluetooth.appendLog("Retrying \(failed.count) device(s) in \(Self.retryDelay)s")
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.retryDelay) {
                self.takeAll(self.keyboardFirst(failed), liftIgnoreFirst: true) { retry in
                    self.busy = false
                    let stillFailed = retry.filter { !$0.value }.count
                    if stillFailed == 0 {
                        self.playConnectedAfterMinimumLoading()
                        self.bluetooth.appendLog("\(label) \(ids.count) device(s) after retry \(Self.since(started))")
                    } else {
                        self.fail("\(stillFailed) device(s) could not be taken. Turn the device off and on, then try again.")
                    }
                }
            }
        }
    }

    /// Each device flashes on arrival; nothing extra at the end.
    private func playConnectedAfterMinimumLoading() {}

    /// A device counts as arrived once macOS has created its HID device, i.e.
    /// once it can actually type or move the pointer — the Bluetooth link comes
    /// up a little before that. Bluetooth HID devices carry the low 32 bits of
    /// the device address (top bit cleared) as their LocationID.
    private func waitForHID(address: String, completion: @escaping (Bool) -> Void) {
        guard let location = Self.locationID(forAddress: address) else { completion(true); return }
        let deadline = Date().addingTimeInterval(Self.hidReadyTimeout)
        func check() {
            if Self.hidDevicePresent(location: location) { completion(true); return }
            if Date() > deadline { completion(false); return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { check() }
        }
        check()
    }

    private static func locationID(forAddress address: String) -> Int? {
        let bytes = address.split(whereSeparator: { $0 == "-" || $0 == ":" }).compactMap { UInt32($0, radix: 16) }
        guard bytes.count == 6 else { return nil }
        let low = (bytes[2] << 24) | (bytes[3] << 16) | (bytes[4] << 8) | bytes[5]
        return Int(low & 0x7FFF_FFFF)
    }

    private static func hidDevicePresent(location: Int) -> Bool {
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        // Generic Desktop page: keyboard (6) or mouse/pointer (2) — the usable interface.
        let matching: [String: Any] = [
            kIOHIDLocationIDKey as String: location,
            kIOHIDPrimaryUsagePageKey as String: 0x01,
        ]
        IOHIDManagerSetDeviceMatching(manager, matching as CFDictionary)
        guard let set = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice> else { return false }
        return !set.isEmpty
    }

    /// The keyboard goes first so its Caps Lock LED can show progress for the rest.
    private func keyboardFirst(_ ids: [String]) -> [String] {
        ids.sorted { a, b in
            let ka = bluetooth.peripherals.first { $0.id == a }?.kind == .keyboard
            let kb = bluetooth.peripherals.first { $0.id == b }?.kind == .keyboard
            return ka && !kb
        }
    }

    func takeAll() {
        // Prefer what the other Mac reports as connected; fall back to everything we know that isn't here.
        peerDevices.forEach { bluetooth.ensureKnown($0) }
        let remote = peerDevices.filter { $0.connected == true }.map(\.id)
        let ids = remote.isEmpty
            ? bluetooth.peripherals.filter { $0.state != .connected && !$0.state.isBusy }.map(\.id)
            : remote
        take(ids)
    }

    // MARK: - Incoming requests

    private func handle(_ message: Message, reply: @escaping (Message) -> Void) {
        switch message.type {
        case "ping":
            reply(Message(type: "pong", devices: bluetooth.deviceInfos(), hotkey: settings.thisMacHotkey))

        case "release":
            let ids = (message.devices ?? []).map(\.id)
            bluetooth.appendLog("\(message.fromName ?? "Peer") asked to release \(ids.count) device(s)")

            releaseAll(ids) { results in
                reply(Message(type: "released", results: results))
            }

        case "take":
            let infos = message.devices ?? []
            infos.forEach { bluetooth.ensureKnown($0) }
            reply(Message(type: "accepted"))
            bluetooth.appendLog("\(message.fromName ?? "Peer") handed over \(infos.count) device(s); taking them")
            busy = true
            let started = Date()
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.postReleaseSettle) { [weak self] in
                self?.takeWithRetry(infos.map(\.id), started: started, label: "Received", freshlyReleased: true)
            }

        default:
            reply(Message(type: "error", error: "unknown request \(message.type)"))
        }
    }

    // MARK: - Sleep

    private func handleSleep(done: @escaping () -> Void) {
        guard settings.handoffOnSleep,
              selectedPeer != nil,
              bluetooth.peripherals.contains(where: { $0.state == .connected }) else {
            done(); return
        }
        let ids = bluetooth.peripherals.filter { $0.state == .connected }.map(\.id)
        bluetooth.appendLog("Going to sleep: handing \(ids.count) device(s) to \(peerName)")
        var called = false
        let finish = { if !called { called = true; done() } }
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { finish() }
        send(ids) { [weak self] ok in
            if ok { self?.handedOffOnSleep = ids }
            finish()
        }
    }

    /// Devices handed to the other Mac because this Mac went to sleep; taken
    /// back on wake when the option is on. Persisted in case the app restarts.
    private var handedOffOnSleep: [String] {
        get { UserDefaults.standard.stringArray(forKey: "handedOffOnSleep") ?? [] }
        set { UserDefaults.standard.set(newValue, forKey: "handedOffOnSleep") }
    }

    private func handleWake() {
        let ids = handedOffOnSleep
        guard settings.takeBackOnWake, !ids.isEmpty else { return }
        handedOffOnSleep = []
        // Wi-Fi needs a moment after wake; the take asks the peer to release first.
        bluetooth.appendLog("Awake: taking back \(ids.count) device(s) handed off at sleep")
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.wakeTakeBackDelay) { [weak self] in
            guard let self, !self.busy else { return }
            let stillAway = ids.filter { id in self.bluetooth.peripherals.first { $0.id == id }?.state != .connected }
            if stillAway.isEmpty { return }
            self.take(stillAway)
        }
    }
    private static let wakeTakeBackDelay: TimeInterval = 4

    // MARK: - Parallel helpers (main queue)

    /// Releases every device; the Bluetooth queue serialises the IPC, but nothing
    /// here waits on anything else. Completion carries per-device success.
    private func releaseAll(_ ids: [String], completion: @escaping ([String: Bool]) -> Void) {
        guard !ids.isEmpty else { completion([:]); return }
        var results: [String: Bool] = [:]
        for id in ids {
            bluetooth.release(id) { ok in
                results[id] = ok
                if results.count == ids.count { completion(results) }
            }
        }
    }

    /// Takes the devices one after another. Pairing two devices at once looked
    /// faster but the controller serialises pairing anyway, and the second
    /// device's link dropped before its HID session was up — it then reconnected
    /// on its own and macOS raised the Connection Request dialog. Sequential
    /// pairing keeps the HID session inside the pairing connection.
    private func takeAll(_ ids: [String], liftIgnoreFirst: Bool = false, freshlyReleased: Bool = false, completion: @escaping ([String: Bool]) -> Void) {
        var results: [String: Bool] = [:]
        var remaining = ids
        func next() {
            guard let id = remaining.first else { completion(results); return }
            remaining.removeFirst()
            bluetooth.take(id, liftIgnoreFirst: liftIgnoreFirst, freshlyReleased: freshlyReleased) { ok in
                results[id] = ok
                guard ok, let p = self.bluetooth.peripherals.first(where: { $0.id == id }) else { next(); return }
                self.waitForHID(address: p.id) { ready in
                    self.bluetooth.appendLog(ready ? "\(p.name): ready to use" : "\(p.name): link up, but no HID device after \(Int(Self.hidReadyTimeout))s")
                    if p.kind == .keyboard { self.capsLock.invalidate() }   // fresh HID device after a (re)pair
                    // One flash per device that arrives, on the keyboard's LED.
                    self.capsLock.playConnected()
                    next()
                }
            }
        }
        next()
    }

    private static func since(_ start: Date) -> String {
        String(format: "(%.2fs)", Date().timeIntervalSince(start))
    }

    private func fail(_ text: String) {
        lastError = text
        bluetooth.appendLog(text)
    }
}
