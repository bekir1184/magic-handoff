import Foundation
import Combine
import CryptoKit
import CommonCrypto

/// User-facing settings persisted in UserDefaults, plus the identity of this Mac.
final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    private let defaults = UserDefaults.standard

    /// Shared secret both Macs hold. Generated on first launch; the user copies one
    /// Mac's code to the other. Everything between the Macs is protected by it.
    @Published var pairingCode: String { didSet { defaults.set(pairingCode, forKey: "pairingCode") } }
    /// Identity of the other Mac.
    @Published var peerID: String? { didSet { defaults.set(peerID, forKey: "peerID") } }
    @Published var peerName: String? { didSet { defaults.set(peerName, forKey: "peerName") } }
    @Published var handoffOnSleep: Bool { didSet { defaults.set(handoffOnSleep, forKey: "handoffOnSleep") } }
    /// Fast switching: release by closing the link and keep the pairing on both
    /// Macs, so the next take is a plain connect instead of a fresh pairing.
    @Published var keepBonds: Bool { didSet { defaults.set(keepBonds, forKey: "keepBonds") } }

    /// Stable random identity of this Mac, generated once.
    let thisMacID: String
    var thisMacName: String { Host.current().localizedName ?? "This Mac" }

    private init() {
        let stored = defaults.string(forKey: "pairingCode") ?? ""
        pairingCode = stored.isEmpty ? Self.generateCode() : stored
        peerID = defaults.string(forKey: "peerID")
        peerName = defaults.string(forKey: "peerName")
        handoffOnSleep = defaults.object(forKey: "handoffOnSleep") as? Bool ?? true
        keepBonds = defaults.object(forKey: "keepBonds") as? Bool ?? false
        if let id = defaults.string(forKey: "thisMacID") {
            thisMacID = id
        } else {
            let id = UUID().uuidString
            defaults.set(id, forKey: "thisMacID")
            thisMacID = id
        }
        if stored.isEmpty { defaults.set(pairingCode, forKey: "pairingCode") }
    }

    // MARK: - Pairing code → pre-shared key

    static func normalize(_ code: String) -> String {
        code.uppercased().filter { $0.isLetter || $0.isNumber }
    }

    var normalizedCode: String { Self.normalize(pairingCode) }
    var hasPairingCode: Bool { normalizedCode.count >= 8 }

    private var cachedKey: (code: String, key: SymmetricKey)?

    /// 256-bit TLS pre-shared key derived from the code with PBKDF2 (200k rounds),
    /// so a captured handshake cannot be brute-forced back to the short code
    /// in any practical time. Same code ⇒ same key on both Macs.
    var presharedKey: SymmetricKey? {
        guard hasPairingCode else { return nil }
        let code = normalizedCode
        if let cached = cachedKey, cached.code == code { return cached.key }
        let key = Self.deriveKey(from: code)
        cachedKey = (code, key)
        return key
    }

    private static func deriveKey(from code: String) -> SymmetricKey {
        let salt = Array("magichandoff-v1".utf8)
        let password = Array(code.utf8)
        var derived = [UInt8](repeating: 0, count: 32)
        _ = CCKeyDerivationPBKDF(
            CCPBKDFAlgorithm(kCCPBKDF2),
            code, password.count,
            salt, salt.count,
            CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
            200_000,
            &derived, derived.count
        )
        return SymmetricKey(data: derived)
    }

    /// Shown in Settings so the user can check both Macs agree. Never broadcast.
    var fingerprint: String? {
        guard let key = presharedKey else { return nil }
        return Self.hex(SHA256.hash(data: Data("fingerprint".utf8) + key.rawData), bytes: 4)
    }

    /// Short tag advertised over Bonjour so the app can tell "same code" from
    /// "different code" before connecting. 16 bits: useless for guessing the
    /// code, enough to avoid confusing two Macs.
    var advertisedTag: String? {
        guard let key = presharedKey else { return nil }
        return Self.hex(SHA256.hash(data: Data("advertise".utf8) + key.rawData), bytes: 2)
    }

    private static func hex<D: Sequence>(_ digest: D, bytes: Int) -> String where D.Element == UInt8 {
        digest.prefix(bytes).map { String(format: "%02X", $0) }.joined()
    }

    static func generateCode() -> String {
        // No 0/O/1/I to avoid transcription mistakes.
        let alphabet = Array("ABCDEFGHJKLMNPQRSTUVWXYZ23456789")
        var code = ""
        for i in 0..<8 {
            if i == 4 { code += "-" }
            code.append(alphabet[Int.random(in: 0..<alphabet.count)])
        }
        return code
    }

    /// Pretty form of whatever the user typed: "abcd efgh" → "ABCD-EFGH".
    static func format(_ code: String) -> String {
        let n = normalize(code)
        guard n.count > 4 else { return n }
        return String(n.prefix(4)) + "-" + String(n.dropFirst(4))
    }
}

private extension SymmetricKey {
    var rawData: Data { withUnsafeBytes { Data($0) } }
}
