import SwiftUI

struct MenuContentView: View {
    @EnvironmentObject private var bluetooth: BluetoothController
    @EnvironmentObject private var handoff: HandoffCoordinator
    @EnvironmentObject private var settings: AppSettings
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            if !settings.onboardingCompleted {
                setupPrompt("Finish the setup to start using Magic Handoff.", button: "Open Setup") {
                    OnboardingWindow.show()
                }
            } else if !handoff.isSetUp {
                setupPrompt("Your other Mac isn't connected yet.", button: "Connect other Mac…") {
                    OnboardingWindow.show(startingAt: .otherMac)
                }
            } else {
                connectedContent
            }
        }
        .padding(12)
        .frame(width: 340)
    }

    private var header: some View {
        HStack {
            Text("Magic Handoff").font(.headline)
            Spacer()
            if handoff.busy { ProgressView().controlSize(.small) }
            Button {
                openSettings()
                NSApp.activate(ignoringOtherApps: true)
            } label: {
                Image(systemName: "gearshape")
            }
            .buttonStyle(.plain)
            .help("Settings")
            Button {
                NSApplication.shared.terminate(nil)
            } label: {
                Image(systemName: "power")
            }
            .buttonStyle(.plain)
            .help("Quit Magic Handoff")
            .keyboardShortcut("q")
        }
    }

    private func setupPrompt(_ text: String, button: String, action: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(text).font(.callout).foregroundStyle(.secondary)
            Button(button, action: action)
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private var connectedContent: some View {
        peerLine

        if !bluetooth.bluetoothAuthorized {
            Label("Bluetooth access is off", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .font(.callout)
        }

        if bluetooth.peripherals.isEmpty {
            Text("No Magic keyboard, trackpad or mouse is known to this Mac yet. Pair one in System Settings → Bluetooth.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .padding(.vertical, 4)
        } else {
            ForEach(bluetooth.peripherals) { p in
                PeripheralRow(
                    peripheral: p,
                    peerName: handoff.peerName,
                    onSend: { handoff.send([p.id]) },
                    onTake: { handoff.take([p.id]) }
                )
            }
        }

        HStack {
            Button("Send all") { handoff.sendAll() }
                .disabled(handoff.busy || handoff.peerStatus != .online || !bluetooth.anyConnected)
            Button("Take all") { handoff.takeAll() }
                .disabled(handoff.busy || bluetooth.allConnected)
            Spacer()
            Text(hotkeyHint).font(.caption).foregroundStyle(.tertiary)
        }
        .controlSize(.small)

        if let error = handoff.lastError {
            Text(error)
                .font(.caption)
                .foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var hotkeyHint: String {
        let mine = settings.thisMacHotkey
        return "⌘⇧\(mine == 1 ? 2 : 1) send · ⌘⇧\(mine) take"
    }

    private var peerLine: some View {
        HStack(spacing: 6) {
            Circle().fill(peerColor).frame(width: 7, height: 7)
            Text("\(handoff.peerName) · \(peerStatusText)")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    private var peerStatusText: String {
        switch handoff.peerStatus {
        case .none: return "not set up"
        case .offline: return "offline"
        case .checking: return "checking…"
        case .online: return "online"
        case .codeMismatch: return "uses a different code"
        }
    }

    private var peerColor: Color {
        switch handoff.peerStatus {
        case .none: return .gray
        case .offline: return .red
        case .checking: return .yellow
        case .online: return .green
        case .codeMismatch: return .orange
        }
    }
}

private struct PeripheralRow: View {
    let peripheral: Peripheral
    let peerName: String
    let onSend: () -> Void
    let onTake: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: peripheral.kind.symbol)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(peripheral.name)
                HStack(spacing: 6) {
                    Circle().fill(dotColor).frame(width: 7, height: 7)
                    Text(peripheral.state.label)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer()
            if peripheral.state.isBusy {
                ProgressView().controlSize(.small)
            } else if peripheral.state == .connected {
                Button("Send", action: onSend).controlSize(.small)
                    .help("Hand this device to \(peerName)")
            } else {
                Button("Take", action: onTake).controlSize(.small)
                    .help("Ask \(peerName) to let go, then connect it here")
            }
        }
        .padding(.vertical, 2)
    }

    private var dotColor: Color {
        switch peripheral.state {
        case .connected: return .green
        case .disconnected: return .gray
        case .releasing, .taking: return .yellow
        case .failed: return .red
        }
    }
}
