import SwiftUI

/// Shown in the menu bar popover until the other Mac is connected.
struct SetupView: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var handoff: HandoffCoordinator
    @EnvironmentObject private var peers: PeerService

    @State private var otherCode = ""
    @State private var copied = false

    private var typedCodeValid: Bool { AppSettings.normalize(otherCode).count >= 8 }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            step(1, "Install Magic Handoff on your other Mac and open it.")

            VStack(alignment: .leading, spacing: 8) {
                step(2, "Enter this Mac's code there:")
                HStack {
                    Text(AppSettings.format(settings.pairingCode))
                        .font(.system(size: 24, weight: .semibold, design: .monospaced))
                        .textSelection(.enabled)
                    Spacer()
                    Button(copied ? "Copied" : "Copy") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(AppSettings.format(settings.pairingCode), forType: .string)
                        copied = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
                    }
                    .controlSize(.small)
                }
                .padding(10)
                .background(Color(nsColor: .controlBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 8))

                Text("…or, if the other Mac already shows a code, type it here:")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack {
                    TextField("XXXX-XXXX", text: $otherCode)
                        .font(.system(.body, design: .monospaced))
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(useTypedCode)
                    Button("Use", action: useTypedCode)
                        .disabled(!typedCodeValid)
                        .controlSize(.small)
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                step(3, handoff.matchingPeers.isEmpty ? "Waiting for the other Mac…" : "Choose the other Mac:")
                if handoff.matchingPeers.isEmpty {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text(peers.listening
                             ? "Both Macs must be on the same Wi-Fi or network."
                             : "Preparing…")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                ForEach(peers.peers) { peer in
                    HStack {
                        Image(systemName: "laptopcomputer")
                        Text(peer.name)
                        Spacer()
                        if handoff.usesSameCode(peer) {
                            Button("Use this Mac") { handoff.selectPeer(peer) }
                                .controlSize(.small)
                        } else {
                            Text("different code")
                                .font(.caption)
                                .foregroundStyle(.orange)
                        }
                    }
                }
            }
        }
    }

    private func useTypedCode() {
        guard typedCodeValid else { return }
        settings.pairingCode = AppSettings.format(otherCode)
        otherCode = ""
    }

    private func step(_ n: Int, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("\(n)")
                .font(.caption.bold())
                .frame(width: 18, height: 18)
                .background(Circle().fill(Color.accentColor))
                .foregroundStyle(.white)
            Text(text)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
