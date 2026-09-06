import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var handoff: HandoffCoordinator
    @EnvironmentObject private var peers: PeerService
    @State private var otherCode = ""

    var body: some View {
        Form {
            Section("This Mac") {
                LabeledContent("Version", value: MenuContentView.version)
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
                Toggle("Show progress on the keyboard's Caps Lock light", isOn: $settings.capsLockAnimations)
                Text("Pulses while the other devices are still connecting; bounces once everything is here. Needs Input Monitoring; results are written to the log in the menu.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack {
                    LEDDot(indicator: handoff.capsLock)
                    Text("Preview (dot mirrors the keyboard LED):")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Searching (4 s)") {
                        handoff.capsLock.diagnose { ok in
                            guard ok else { return }
                            handoff.capsLock.startLoading()
                            DispatchQueue.main.asyncAfter(deadline: .now() + 4) { handoff.capsLock.stopLoading() }
                        }
                    }
                    Button("Connected") {
                        handoff.capsLock.diagnose { ok in
                            guard ok else { return }
                            handoff.capsLock.playConnected()
                        }
                    }
                    Button("Goodbye") {
                        handoff.capsLock.diagnose { ok in
                            guard ok else { return }
                            handoff.capsLock.playGoodbye()
                        }
                    }
                }
                .disabled(!settings.capsLockAnimations)
                Toggle("Experimental: keep the pairing on both Macs", isOn: $settings.keepBonds)
                Text("Off (recommended): releasing forgets the device here and the other Mac pairs it fresh, about 3–5 s. On: releasing only closes the link; this is faster for the Mac that paired last, but a Magic device that still considers itself owned refuses to pair with the other Mac.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
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


/// On-screen twin of the Caps Lock LED, to compare timing against the keyboard.
private struct LEDDot: View {
    @ObservedObject var indicator: CapsLockIndicator

    var body: some View {
        Circle()
            .fill(indicator.ledOn ? Color.green : Color.gray.opacity(0.35))
            .frame(width: 14, height: 14)
            .shadow(color: indicator.ledOn ? Color.green.opacity(0.8) : .clear, radius: 6)
            .animation(nil, value: indicator.ledOn)
    }
}
