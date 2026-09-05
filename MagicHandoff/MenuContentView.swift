import SwiftUI

struct MenuContentView: View {
    @EnvironmentObject private var bluetooth: BluetoothController
    @EnvironmentObject private var handoff: HandoffCoordinator
    @EnvironmentObject private var settings: AppSettings
    @Environment(\.openSettings) private var openSettings

    private var hasPeer: Bool { settings.peerID != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            peerLine

            if !bluetooth.bluetoothAuthorized {
                Label("Bluetooth access required", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .font(.callout)
            }

            if bluetooth.peripherals.isEmpty {
                Text("No Magic keyboard, trackpad or mouse is known to this Mac yet.\nPair one in System Settings → Bluetooth, or scan for nearby devices below.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 8)
            } else {
                ForEach(bluetooth.peripherals) { p in
                    PeripheralRow(
                        peripheral: p,
                        hasPeer: hasPeer,
                        peerName: handoff.peerName,
                        onSend: { handoff.send([p.id]) },
                        onTake: { handoff.take([p.id]) },
                        onRelease: { bluetooth.release(p.id) }
                    )
                    .contextMenu {
                        Button("Release (forget on this Mac only)") { bluetooth.release(p.id) }
                        Button("Remove from list") { bluetooth.forget(p.id) }
                    }
                }
            }

            if hasPeer {
                HStack {
                    Button("Send all to \(handoff.peerName)") { handoff.sendAll() }
                        .disabled(handoff.busy || handoff.peerStatus != .online || !bluetooth.anyConnected)
                    Button("Take all") { handoff.takeAll() }
                        .disabled(handoff.busy)
                }
                .controlSize(.small)
            }

            if let error = handoff.lastError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider()
            LogView(lines: bluetooth.log, onClear: bluetooth.clearLog)
            Divider()

            HStack {
                Button("Refresh") { bluetooth.refresh(); handoff.ping() }
                Button(bluetooth.isScanning ? "Scanning…" : "Scan nearby") { bluetooth.scanNearby() }
                    .disabled(bluetooth.isScanning)
                Spacer()
                Button("Quit") { NSApplication.shared.terminate(nil) }
                    .keyboardShortcut("q")
            }
            .controlSize(.small)
        }
        .padding(12)
        .frame(width: 380)
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
        }
    }

    @ViewBuilder
    private var peerLine: some View {
        HStack(spacing: 6) {
            Circle().fill(peerColor).frame(width: 7, height: 7)
            if hasPeer {
                Text("\(handoff.peerName) · \(peerStatusText)")
            } else {
                Text("No other Mac set up")
                Button("Set up…") {
                    openSettings()
                    NSApp.activate(ignoringOtherApps: true)
                }
                .buttonStyle(.link)
            }
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
        }
    }

    private var peerColor: Color {
        switch handoff.peerStatus {
        case .none: return .gray
        case .offline: return .red
        case .checking: return .yellow
        case .online: return .green
        }
    }
}

private struct PeripheralRow: View {
    let peripheral: Peripheral
    let hasPeer: Bool
    let peerName: String
    let onSend: () -> Void
    let onTake: () -> Void
    let onRelease: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: peripheral.kind.symbol)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(peripheral.name).font(.body)
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
                if hasPeer {
                    Button("Send", action: onSend).controlSize(.small)
                        .help("Hand this device to \(peerName)")
                } else {
                    Button("Release", action: onRelease).controlSize(.small)
                }
            } else {
                Button("Take", action: onTake).controlSize(.small)
                    .help(hasPeer ? "Ask \(peerName) to let go, then connect it here" : "Connect it here")
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

private struct LogView: View {
    let lines: [String]
    let onClear: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Log").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Clear", action: onClear).controlSize(.mini).buttonStyle(.plain)
                    .foregroundStyle(.secondary)
            }
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 1) {
                        ForEach(Array(lines.enumerated()), id: \.offset) { i, line in
                            Text(line)
                                .font(.system(size: 10, design: .monospaced))
                                .textSelection(.enabled)
                                .id(i)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(height: 120)
                .onChange(of: lines.count) { _, n in
                    if n > 0 { proxy.scrollTo(n - 1, anchor: .bottom) }
                }
            }
            .background(Color(nsColor: .textBackgroundColor).opacity(0.5))
            .clipShape(RoundedRectangle(cornerRadius: 6))
        }
    }
}
