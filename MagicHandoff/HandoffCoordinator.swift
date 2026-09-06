import Foundation
import Combine

/// Orchestrates a handoff between this Mac and the other one.
///
/// Send = ask the peer to start taking, then release here. The peer is already
///        paging the devices while we let go, so they connect the moment they are free.
/// Take = ask the peer to release and, without waiting for the answer, start
///        pairing here. Same overlap, from the other side.
///
/// Devices are handled in parallel, and each stage is timed in the log.
final class HandoffCoordinator: ObservableObject {
    enum PeerStatus: Equatable { case none, offline, checking, online, codeMismatch }

    @Published private(set) var peerStatus: PeerStatus = .none
    @Published private(set) var peerDevices: [DeviceInfo] = []
    @Published private(set) var busy = false
    @Published var lastError: String?

    let bluetooth: BluetoothController
    let settings: AppSettings
    let peers: PeerService

    private let sleepMonitor = SleepMonitor()
    private var pingTimer: Timer?
    private var cancellables = Set<AnyCancellable>()

    init(bluetooth: BluetoothController, settings: AppSettings) {
        self.bluetooth = bluetooth
        self.settings = settings
        self.peers = PeerService(settings: settings)

        peers.logger = { [weak bluetooth] line in bluetooth?.appendLog(line) }
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
        }

        pingTimer = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { [weak self] _ in self?.ping() }
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
                if let name = reply.fromName, name != self.settings.peerName { self.settings.peerName = name }
            case .failure(let error):
                self.peerStatus = .offline
                self.bluetooth.appendLog("\(peer.name) unreachable: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Send (this Mac → other Mac)

    func send(_ ids: [String], completion: ((Bool) -> Void)? = nil) {
        let infos = ids.compactMap { bluetooth.deviceInfo($0) }
        guard !infos.isEmpty else { completion?(true); return }
        guard let peer = selectedPeer, peerStatus == .online else {
            fail("\(peerName) is not reachable right now; nothing was released")
            completion?(false); return
        }
        busy = true
        lastError = nil
        let started = Date()
        // Release first (it is near-instant), then tell the peer. A pairing attempt
        // that starts while the device is still linked here fails with "no connection".
        releaseAll(infos.map(\.id)) { [weak self] results in
            guard let self else { return }
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

    func sendAll(completion: ((Bool) -> Void)? = nil) {
        send(bluetooth.peripherals.filter { $0.state == .connected }.map(\.id), completion: completion)
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
                self.takeWithRetry(infos.map(\.id), started: started, label: "Took")
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

    private func takeWithRetry(_ ids: [String], started: Date, label: String) {
        takeAll(ids) { [weak self] results in
            guard let self else { return }
            let failed = results.filter { !$0.value }.map(\.key)
            if failed.isEmpty {
                self.busy = false
                self.bluetooth.appendLog("\(label) \(ids.count) device(s) \(Self.since(started))")
                return
            }
            self.bluetooth.appendLog("Retrying \(failed.count) device(s) in \(Self.retryDelay)s")
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.retryDelay) {
                self.takeAll(failed) { retry in
                    self.busy = false
                    let stillFailed = retry.filter { !$0.value }.count
                    if stillFailed == 0 {
                        self.bluetooth.appendLog("\(label) \(ids.count) device(s) after retry \(Self.since(started))")
                    } else {
                        self.fail("\(stillFailed) device(s) could not be taken. Turn the device off and on, then try again.")
                    }
                }
            }
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
            reply(Message(type: "pong", devices: bluetooth.deviceInfos()))

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
                self?.takeWithRetry(infos.map(\.id), started: started, label: "Received")
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
        bluetooth.appendLog("Going to sleep: handing peripherals to \(peerName)")
        var called = false
        let finish = { if !called { called = true; done() } }
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { finish() }
        sendAll { _ in finish() }
    }

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

    /// Starts taking every device at once; pairing attempts run concurrently.
    private func takeAll(_ ids: [String], completion: @escaping ([String: Bool]) -> Void) {
        guard !ids.isEmpty else { completion([:]); return }
        var results: [String: Bool] = [:]
        for id in ids {
            bluetooth.take(id) { ok in
                results[id] = ok
                if results.count == ids.count { completion(results) }
            }
        }
    }

    private static func since(_ start: Date) -> String {
        String(format: "(%.2fs)", Date().timeIntervalSince(start))
    }

    private func fail(_ text: String) {
        lastError = text
        bluetooth.appendLog(text)
    }
}
