import Foundation
import Network
import Combine
import CryptoKit
import Security

// MARK: - Wire format

struct DeviceInfo: Codable, Equatable {
    let id: String
    let name: String
    let kind: String
    var connected: Bool?
}

/// One JSON message per connection: the caller sends a request, the listener
/// answers with exactly one reply, then the connection is closed.
struct Message: Codable {
    var type: String
    var fromID: String?
    var fromName: String?
    var devices: [DeviceInfo]?
    var results: [String: Bool]?
    var error: String?
    /// The sender's hotkey number (1 or 2), carried in pong so both Macs can spot a clash.
    var hotkey: Int?
}

struct Peer: Identifiable, Equatable {
    let id: String
    let name: String
    /// Short tag of the pairing code that Mac uses (see AppSettings.advertisedTag).
    let tag: String?
    let endpoint: NWEndpoint
}

enum PeerError: LocalizedError {
    case notPaired, timeout, closed, badFrame, noPeer

    var errorDescription: String? {
        switch self {
        case .notPaired: return "no pairing code set"
        case .timeout: return "timed out"
        case .closed: return "connection closed"
        case .badFrame: return "malformed message"
        case .noPeer: return "other Mac not found on the network"
        }
    }
}

// MARK: - Service

/// Finds the other Mac with Bonjour and exchanges request/reply messages with it
/// over TLS. Authentication and encryption come from a TLS pre-shared key derived
/// from the pairing code, so the OS does the crypto and nothing is hand-rolled.
final class PeerService: ObservableObject {
    static let serviceType = "_magichandoff._tcp"
    private static let pskIdentity = Data("magichandoff".utf8)

    @Published private(set) var peers: [Peer] = []
    @Published private(set) var listening = false

    enum LocalNetworkState { case unknown, allowed, denied }
    /// Best available read on the Local Network permission (macOS offers no direct query).
    @Published private(set) var localNetwork: LocalNetworkState = .unknown
    private(set) var started = false

    /// Called on the main queue for every incoming request; must call `reply` once.
    var requestHandler: ((Message, @escaping (Message) -> Void) -> Void)?
    /// Diagnostic lines, delivered on the main queue.
    var logger: ((String) -> Void)?

    private let settings: AppSettings
    private let queue = DispatchQueue(label: "com.bekirersever.magichandoff.network")
    private var listener: NWListener?
    private var browser: NWBrowser?
    private var incoming: [ObjectIdentifier: NWConnection] = [:]
    private var cancellables = Set<AnyCancellable>()

    init(settings: AppSettings) {
        self.settings = settings
        // Re-key the listener whenever the pairing code changes.
        settings.$pairingCode
            .removeDuplicates()
            .dropFirst()
            .debounce(for: .seconds(1), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in if self?.started == true { self?.startListener() } }
            .store(in: &cancellables)
    }

    /// Starts advertising and browsing. The first Bonjour activity is what makes
    /// macOS ask for Local Network access, so this runs from the setup screen
    /// (or at launch once setup is done).
    func start() {
        guard !started else { return }
        started = true
        startBrowser()
        startListener()
    }

    // MARK: TLS with pre-shared key

    private func secureParameters() -> NWParameters? {
        guard let key = settings.presharedKey else { return nil }
        let tls = NWProtocolTLS.Options()
        let options = tls.securityProtocolOptions
        let keyData = key.withUnsafeBytes { DispatchData(bytes: $0) }
        let identity = Self.pskIdentity.withUnsafeBytes { DispatchData(bytes: $0) }
        sec_protocol_options_add_pre_shared_key(options, keyData as __DispatchData, identity as __DispatchData)
        sec_protocol_options_append_tls_ciphersuite(
            options, tls_ciphersuite_t(rawValue: UInt16(TLS_PSK_WITH_AES_128_GCM_SHA256))!)
        // PSK cipher suites are TLS 1.2 constructs.
        sec_protocol_options_set_min_tls_protocol_version(options, .TLSv12)
        sec_protocol_options_set_max_tls_protocol_version(options, .TLSv12)

        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        tcp.connectionTimeout = 5
        return NWParameters(tls: tls, tcp: tcp)
    }

    // MARK: Listener (advertised over Bonjour)

    private func startListener() {
        listener?.cancel()
        listener = nil
        DispatchQueue.main.async { self.listening = false }
        guard let params = secureParameters() else {
            log("Not listening: set a pairing code first")
            return
        }
        do {
            let l = try NWListener(using: params)
            let txt = NWTXTRecord([
                "id": settings.thisMacID,
                "name": settings.thisMacName,
                "tag": settings.advertisedTag ?? "",
            ])
            let serviceName = String("\(settings.thisMacName) [\(settings.thisMacID.prefix(4))]".prefix(60))
            l.service = NWListener.Service(name: serviceName, type: Self.serviceType, domain: nil, txtRecord: txt)
            l.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready:
                    self?.log("Listening on port \(l.port.map { String(describing: $0) } ?? "?")")
                    DispatchQueue.main.async { self?.listening = true }
                case .failed(let error):
                    self?.log("Listener failed: \(error.localizedDescription)")
                    DispatchQueue.main.async { self?.listening = false }
                default:
                    break
                }
            }
            l.newConnectionHandler = { [weak self] connection in self?.handleIncoming(connection) }
            l.start(queue: queue)
            listener = l
        } catch {
            log("Listener error: \(error.localizedDescription)")
        }
    }

    private func handleIncoming(_ connection: NWConnection) {
        let key = ObjectIdentifier(connection)
        incoming[key] = connection
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                Self.receiveMessage(on: connection) { result in
                    switch result {
                    case .failure(let error):
                        // ECONNRESET after the caller got its reply is normal; only report real failures.
                        if case .posix(let code) = error as? NWError, code == .ECONNRESET {} else {
                            self.log("Incoming request failed: \(error.localizedDescription)")
                        }
                        connection.cancel()
                    case .success(let message):
                        self.log("← \(message.type) from \(message.fromName ?? "?")")
                        DispatchQueue.main.async {
                            guard let handler = self.requestHandler else { connection.cancel(); return }
                            handler(message) { reply in
                                var stamped = reply
                                stamped.fromID = self.settings.thisMacID
                                stamped.fromName = self.settings.thisMacName
                                guard let data = try? Self.encode(stamped) else { connection.cancel(); return }
                                connection.send(content: data, completion: .contentProcessed { _ in
                                    connection.send(content: nil, contentContext: .finalMessage, isComplete: true,
                                                    completion: .contentProcessed { _ in connection.cancel() })
                                })
                            }
                        }
                    }
                }
            case .failed, .cancelled:
                self.queue.async { self.incoming.removeValue(forKey: key) }
            default:
                break
            }
        }
        connection.start(queue: queue)
    }

    // MARK: Browser

    private func startBrowser() {
        browser?.cancel()
        let b = NWBrowser(for: .bonjourWithTXTRecord(type: Self.serviceType, domain: nil), using: NWParameters())
        b.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                DispatchQueue.main.async { self.localNetwork = .allowed }
            case .waiting(let error):
                // kDNSServiceErr_PolicyDenied (-65570): Local Network access refused.
                if case .dns(let code) = error, code == -65570 {
                    DispatchQueue.main.async { self.localNetwork = .denied }
                    self.log("Local Network access is off; the other Mac cannot be found")
                }
            case .failed(let error):
                self.log("Browser failed: \(error.localizedDescription); retrying")
                self.queue.asyncAfter(deadline: .now() + 5) { self.startBrowser() }
            default:
                break
            }
        }
        b.browseResultsChangedHandler = { [weak self] results, _ in self?.updatePeers(results) }
        b.start(queue: queue)
        browser = b
    }

    private func updatePeers(_ results: Set<NWBrowser.Result>) {
        var found: [Peer] = []
        for result in results {
            guard case .bonjour(let txt) = result.metadata,
                  let id = txt.dictionary["id"],
                  id != settings.thisMacID else { continue }
            let tag = txt.dictionary["tag"].flatMap { $0.isEmpty ? nil : $0 }
            found.append(Peer(id: id, name: txt.dictionary["name"] ?? "Mac", tag: tag, endpoint: result.endpoint))
        }
        found.sort { $0.name < $1.name }
        DispatchQueue.main.async {
            if found != self.peers { self.peers = found }
            if !found.isEmpty { self.localNetwork = .allowed }
        }
    }

    // MARK: Request / reply

    func request(_ message: Message, to peer: Peer, timeout: TimeInterval = 12,
                 completion: @escaping (Result<Message, Error>) -> Void) {
        guard let params = secureParameters() else {
            completion(.failure(PeerError.notPaired)); return
        }
        var stamped = message
        stamped.fromID = settings.thisMacID
        stamped.fromName = settings.thisMacName

        let connection = NWConnection(to: peer.endpoint, using: params)
        var finished = false
        let finish: (Result<Message, Error>) -> Void = { [queue] result in
            queue.async {
                guard !finished else { return }
                finished = true
                connection.cancel()
                DispatchQueue.main.async { completion(result) }
            }
        }
        let timer = DispatchWorkItem { finish(.failure(PeerError.timeout)) }
        queue.asyncAfter(deadline: .now() + timeout, execute: timer)

        connection.stateUpdateHandler = { state in
            switch state {
            case .ready:
                guard let data = try? Self.encode(stamped) else { finish(.failure(PeerError.badFrame)); return }
                connection.send(content: data, completion: .contentProcessed { error in
                    if let error { finish(.failure(error)); return }
                    Self.receiveMessage(on: connection) { result in
                        timer.cancel()
                        finish(result)
                    }
                })
            case .failed(let error):
                finish(.failure(error))
            case .waiting(let error):
                // No route / host down: fail fast instead of waiting for connectivity.
                finish(.failure(error))
            default:
                break
            }
        }
        log("→ \(message.type) to \(peer.name)")
        connection.start(queue: queue)
    }

    // MARK: Framing (4-byte big-endian length + JSON)

    private static func encode(_ message: Message) throws -> Data {
        let body = try JSONEncoder().encode(message)
        var length = UInt32(body.count).bigEndian
        return Data(bytes: &length, count: 4) + body
    }

    private static func receiveMessage(on connection: NWConnection,
                                       completion: @escaping (Result<Message, Error>) -> Void) {
        connection.receive(minimumIncompleteLength: 4, maximumLength: 4) { header, _, _, error in
            guard let header, header.count == 4 else {
                completion(.failure(error ?? PeerError.closed)); return
            }
            let length = header.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }.bigEndian
            guard length > 0, length < 1_000_000 else { completion(.failure(PeerError.badFrame)); return }
            connection.receive(minimumIncompleteLength: Int(length), maximumLength: Int(length)) { body, _, _, error in
                guard let body, body.count == Int(length) else {
                    completion(.failure(error ?? PeerError.closed)); return
                }
                do {
                    completion(.success(try JSONDecoder().decode(Message.self, from: body)))
                } catch {
                    completion(.failure(error))
                }
            }
        }
    }

    private func log(_ line: String) {
        DispatchQueue.main.async { self.logger?(line) }
    }
}
