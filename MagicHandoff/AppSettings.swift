import Foundation
import Combine
import CryptoKit

/// User-facing settings persisted in UserDefaults, plus the identity of this Mac.
final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    private let defaults = UserDefaults.standard

    /// Shared secret typed on both Macs. Everything between the Macs is protected by it.
    @Published var pairingCode: String { didSet { defaults.set(pairingCode, forKey: "pairingCode") } }
    /// Identity of the other Mac chosen in Settings.
    @Published var peerID: String? { didSet { defaults.set(peerID, forKey: "peerID") } }
    @Published var peerName: String? { didSet { defaults.set(peerName, forKey: "peerName") } }
    @Published var handoffOnSleep: Bool { didSet { defaults.set(handoffOnSleep, forKey: "handoffOnSleep") } }

    /// Stable random identity of this Mac, generated once.
    let thisMacID: String
    var thisMacName: String { Host.current().localizedName ?? "This Mac" }

    private init() {
        pairingCode = defaults.string(forKey: "pairingCode") ?? ""
        peerID = defaults.string(forKey: "peerID")
        peerName = defaults.string(forKey: "peerName")
        handoffOnSleep = defaults.object(forKey: "handoffOnSleep") as? Bool ?? true
        if let id = defaults.string(forKey: "thisMacID") {
            thisMacID = id
        } else {
            let id = UUID().uuidString
            defaults.set(id, forKey: "thisMacID")
            thisMacID = id
        }
    }

    // MARK: - Pairing code → pre-shared key

    var normalizedCode: String {
        pairingCode.uppercased().filter { !$0.isWhitespace && $0 != "-" }
    }

    var hasPairingCode: Bool { normalizedCode.count >= 8 }

    /// 256-bit TLS pre-shared key derived from the code. Same code ⇒ same key on both Macs.
    var presharedKey: SymmetricKey? {
        guard hasPairingCode else { return nil }
        return HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: Data(normalizedCode.utf8)),
            salt: Data("magichandoff-v1".utf8),
            info: Data("tls-psk".utf8),
            outputByteCount: 32
        )
    }

    /// Short value shown in Settings so the user can check both Macs agree.
    var fingerprint: String? {
        guard let key = presharedKey else { return nil }
        let digest = SHA256.hash(data: key.withUnsafeBytes { Data($0) })
        return digest.prefix(4).map { String(format: "%02X", $0) }.joined()
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
}
