import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var handoff: HandoffCoordinator
    @EnvironmentObject private var peers: PeerService
    @State private var otherCode = ""

    var body: some View {
        Form {
            Section("This Mac") {
                LabeledContent("Name", value: settings.thisMacName)
                LabeledContent("ID", value: String(settings.thisMacID.prefix(8)))
                LabeledContent("Listening", value: peers.listening ? "Yes" : "No – set a pairing code")
            }

            Section("Pairing code") {
                Text("Both Macs must hold the same code. It is the key that authenticates and encrypts everything they say to each other.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack {
                    Text(AppSettings.format(settings.pairingCode))
                        .font(.system(size: 20, weight: .semibold, design: .monospaced))
                        .textSelection(.enabled)
                    Spacer()
                    Button("New code") { settings.pairingCode = AppSettings.generateCode() }
                }
                HStack {
                    TextField("Enter the other Mac's code instead", text: $otherCode)
                        .font(.system(.body, design: .monospaced))
                        .textFieldStyle(.roundedBorder)
                    Button("Use") {
                        settings.pairingCode = AppSettings.format(otherCode)
                        otherCode = ""
                    }
                    .disabled(AppSettings.normalize(otherCode).count < 8)
                }
                if let fingerprint = settings.fingerprint {
                    LabeledContent("Fingerprint", value: fingerprint)
                    Text("Both Macs must show the same fingerprint.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Other Mac") {
                if peers.peers.isEmpty {
                    Text("No other Mac found yet. Run Magic Handoff there with the same pairing code, on the same network.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                ForEach(peers.peers) { peer in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(peer.name)
                            Text(String(peer.id.prefix(8)))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if !handoff.usesSameCode(peer) {
                            Text("different code")
                                .font(.caption)
                                .foregroundStyle(.orange)
                        }
                        if settings.peerID == peer.id {
                            Label("Selected", systemImage: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                            Button("Ping") { handoff.ping() }
                        } else {
                            Button("Select") { handoff.selectPeer(peer) }
                        }
                    }
                }
                if settings.peerID != nil {
                    LabeledContent("Status", value: statusText)
                    Button("Forget other Mac", role: .destructive) { handoff.selectPeer(nil) }
                }
            }

            Section("Behavior") {
                Toggle("Hand off peripherals to the other Mac when this Mac goes to sleep",
                       isOn: $settings.handoffOnSleep)
            }
        }
        .formStyle(.grouped)
        .frame(width: 480, height: 560)
    }

    private var statusText: String {
        switch handoff.peerStatus {
        case .none: return "Not configured"
        case .offline: return "Offline"
        case .checking: return "Checking…"
        case .online: return "Online · \(handoff.peerDevices.filter { $0.connected == true }.count) device(s) connected there"
        case .codeMismatch: return "That Mac uses a different pairing code"
        }
    }
}
