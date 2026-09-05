import SwiftUI

struct MenuContentView: View {
    @EnvironmentObject private var bluetooth: BluetoothController

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Magic Handoff").font(.headline)
                Spacer()
                Text("prototype · phase 1").font(.caption).foregroundStyle(.secondary)
            }

            if !bluetooth.bluetoothAuthorized {
                Label("Bluetooth access required", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .font(.callout)
            }

            if bluetooth.peripherals.isEmpty {
                Text("No Magic keyboard, trackpad or mouse is paired with this Mac.\nPair one in System Settings → Bluetooth, or scan for nearby devices below.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 8)
            } else {
                ForEach(bluetooth.peripherals) { p in
                    PeripheralRow(peripheral: p,
                                  onRelease: { bluetooth.release(p.id) },
                                  onTake: { bluetooth.take(p.id) })
                        .contextMenu {
                            Button("Remove from list") { bluetooth.forget(p.id) }
                        }
                }
            }

            Divider()

            LogView(lines: bluetooth.log, onClear: bluetooth.clearLog)

            Divider()

            HStack {
                Button("Refresh") { bluetooth.refresh() }
                Button(bluetooth.isScanning ? "Scanning…" : "Scan nearby") { bluetooth.scanNearby() }
                    .disabled(bluetooth.isScanning)
                Spacer()
                Button("Quit") { NSApplication.shared.terminate(nil) }
                    .keyboardShortcut("q")
            }
            .controlSize(.small)
        }
        .padding(12)
        .frame(width: 360)
    }
}

private struct PeripheralRow: View {
    let peripheral: Peripheral
    let onRelease: () -> Void
    let onTake: () -> Void

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
                Button("Release", action: onRelease).controlSize(.small)
            } else {
                Button("Take", action: onTake).controlSize(.small)
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
                .frame(height: 110)
                .onChange(of: lines.count) { _, n in
                    if n > 0 { proxy.scrollTo(n - 1, anchor: .bottom) }
                }
            }
            .background(Color(nsColor: .textBackgroundColor).opacity(0.5))
            .clipShape(RoundedRectangle(cornerRadius: 6))
        }
    }
}
