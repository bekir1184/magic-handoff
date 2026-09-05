import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var handoff: HandoffCoordinator
    @EnvironmentObject private var peers: PeerService

    var body: some View {
        Form {
            Section("This Mac") {
                LabeledContent("Name", value: settings.thisMacName)
                LabeledContent("ID", value: String(settings.thisMacID.prefix(8)))
                LabeledContent("Listening", value: peers.listening ? "Yes" : "No – set a pairing code")
            }

            Section("Pairing code") {
                Text("Type the same code on both Macs. It becomes the key that authenticates and encrypts everything they say to each other.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack {
                    TextField("XXXX-XXXX", text: $settings.pairingCode)
                        .font(.system(.body, design: .monospaced))
                        .textFieldStyle(.roundedBorder)
                    Button("Generate") { settings.pairingCode = AppSettings.generateCode() }
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
        }
    }
}
