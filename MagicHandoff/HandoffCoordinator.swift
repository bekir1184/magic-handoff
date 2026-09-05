import Foundation
import Combine

/// Orchestrates a handoff between this Mac and the other one.
///
/// Send = release here, then ask the peer to take.
/// Take = ask the peer to release (best effort), then take here.
final class HandoffCoordinator: ObservableObject {
    enum PeerStatus: Equatable { case none, offline, checking, online }

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

    func selectPeer(_ peer: Peer?) {
        settings.peerID = peer?.id
        settings.peerName = peer?.name
        peerDevices = []
    }

    private func peerListChanged() {
        guard settings.peerID != nil else { peerStatus = .none; return }
        guard selectedPeer != nil else { peerStatus = .offline; return }
        ping()
    }

    func ping() {
        guard let peer = selectedPeer else {
            peerStatus = settings.peerID == nil ? .none : .offline
            return
        }
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
        guard let peer = selectedPeer else {
            fail("\(peerName) is not on the network right now")
            completion?(false); return
        }
        busy = true
        lastError = nil
        releaseSequentially(infos.map(\.id)) { [weak self] in
            guard let self else { return }
            self.peers.request(Message(type: "take", devices: infos), to: peer) { result in
                self.busy = false
                switch result {
                case .success:
                    self.bluetooth.appendLog("\(peer.name) is taking \(infos.count) device(s)")
                    completion?(true)
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
        let takeLocally = { [weak self] in
            self?.takeSequentially(infos.map(\.id)) { self?.busy = false }
        }
        guard let peer = selectedPeer else { takeLocally(); return }
        peers.request(Message(type: "release", devices: infos), to: peer) { [weak self] result in
            if case .failure(let error) = result {
                self?.bluetooth.appendLog("\(peer.name) unreachable (\(error.localizedDescription)); taking directly")
            }
            // Let the unbond settle on the other side before paging the device.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { takeLocally() }
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
            var results: [String: Bool] = [:]
            var remaining = ids
            func next() {
                guard let id = remaining.first else {
                    reply(Message(type: "released", results: results)); return
                }
                remaining.removeFirst()
                bluetooth.release(id) { ok in
                    results[id] = ok
                    next()
                }
            }
            next()

        case "take":
            let infos = message.devices ?? []
            infos.forEach { bluetooth.ensureKnown($0) }
            reply(Message(type: "accepted"))
            bluetooth.appendLog("\(message.fromName ?? "Peer") handed over \(infos.count) device(s); taking them")
            busy = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                self?.takeSequentially(infos.map(\.id)) { self?.busy = false }
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

    // MARK: - Helpers

    private func releaseSequentially(_ ids: [String], completion: @escaping () -> Void) {
        var remaining = ids
        func next() {
            guard let id = remaining.first else { completion(); return }
            remaining.removeFirst()
            bluetooth.release(id) { _ in next() }
        }
        next()
    }

    private func takeSequentially(_ ids: [String], completion: @escaping () -> Void) {
        var remaining = ids
        func next() {
            guard let id = remaining.first else { completion(); return }
            remaining.removeFirst()
            bluetooth.take(id) { _ in next() }
        }
        next()
    }

    private func fail(_ text: String) {
        lastError = text
        bluetooth.appendLog(text)
    }
}
