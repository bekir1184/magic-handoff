import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettings()
                .tabItem { Label("General", systemImage: "gearshape") }
            KeyboardLightSettings()
                .tabItem { Label("Keyboard Light", systemImage: "keyboard") }
            AdvancedSettings()
                .tabItem { Label("Advanced", systemImage: "wrench.and.screwdriver") }
        }
        .frame(width: 520, height: 560)
    }
}

// MARK: - General

private struct GeneralSettings: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var handoff: HandoffCoordinator
    @EnvironmentObject private var peers: PeerService
    @State private var otherCode = ""

    var body: some View {
        Form {
            Section("Other Mac") {
                if peers.peers.isEmpty {
                    Text("No other Mac found yet. Run Magic Handoff there with the same pairing code, on the same network.")
                        .foregroundStyle(.secondary)
                }
                ForEach(peers.peers) { peer in
                    HStack {
                        Text(peer.name)
                        if !handoff.usesSameCode(peer) {
                            Text("different code").font(.caption).foregroundStyle(.orange)
                        }
                        Spacer()
                        if settings.peerID == peer.id {
                            Label("Selected", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                        } else {
                            Button("Select") { handoff.selectPeer(peer) }
                        }
                    }
                }
                if settings.peerID != nil {
                    LabeledContent("Status", value: statusText)
                }
            }

            Section("Pairing code") {
                Text("Both Macs must hold the same code; it is the key that secures everything they say to each other.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack {
                    Text(AppSettings.format(settings.pairingCode))
                        .font(.body.weight(.medium))
                        .monospacedDigit()
                        .textSelection(.enabled)
                    Spacer()
                    Button("Copy") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(AppSettings.format(settings.pairingCode), forType: .string)
                    }
                    Button("New code") { settings.pairingCode = AppSettings.generateCode() }
                }
                HStack {
                    TextField("Enter the other Mac's code instead", text: $otherCode)
                        .textFieldStyle(.roundedBorder)
                    Button("Use") {
                        settings.pairingCode = AppSettings.format(otherCode)
                        otherCode = ""
                    }
                    .disabled(AppSettings.normalize(otherCode).count < 8)
                }
            }

            Section("Hotkeys") {
                Picker("This Mac is", selection: $settings.thisMacHotkey) {
                    Text("⌘⇧1").tag(1)
                    Text("⌘⇧2").tag(2)
                }
                .pickerStyle(.segmented)
                Text(hotkeyHelp)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Sleep") {
                Toggle("Hand devices to the other Mac when this Mac goes to sleep", isOn: $settings.handoffOnSleep)
                Toggle("Take them back when this Mac wakes up", isOn: $settings.takeBackOnWake)
                    .disabled(!settings.handoffOnSleep)
            }
        }
        .formStyle(.grouped)
    }

    private var statusText: String {
        switch handoff.peerStatus {
        case .none: return "Not configured"
        case .offline: return "Offline"
        case .checking: return "Checking…"
        case .online: return "Online · \(handoff.peerDevices.filter { $0.connected == true }.count) device(s) there"
        case .codeMismatch: return "That Mac uses a different pairing code"
        }
    }

    private var hotkeyHelp: String {
        let mine = settings.thisMacHotkey
        let other = mine == 1 ? 2 : 1
        var text = "⌘⇧\(other) sends everything to \(handoff.peerName); ⌘⇧\(mine) brings everything here. Set the other Mac to ⌘⇧\(other)."
        if let h = handoff.peerHotkey, h == mine { text += " ⚠️ The other Mac is also set to ⌘⇧\(h)." }
        return text
    }
}

// MARK: - Keyboard light

private struct KeyboardLightSettings: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var handoff: HandoffCoordinator
    @State private var granted = CapsLockIndicator.inputMonitoringGranted
    private let tick = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        Form {
            Section {
                Toggle("Flash the keyboard's Caps Lock light as each device arrives", isOn: $settings.capsLockAnimations)
                Text("Two short pulses and a long flash on the Magic Keyboard when a device has connected and is ready to use. Off by default: it needs the Input Monitoring permission, which is only requested from the Allow button below.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if settings.capsLockAnimations {
                Section("Permission") {
                    if granted {
                        StatusRow(ok: true, text: "Input Monitoring granted")
                    } else {
                        StatusRow(ok: false, text: "Input Monitoring is needed to drive the light")
                        Text("Click Allow, turn on Magic Handoff in the list that opens, then relaunch the app.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        HStack {
                            Button("Allow…") { CapsLockIndicator.requestInputMonitoring() }
                            Button("Relaunch") { CapsLockIndicator.relaunch() }
                        }
                    }
                }

                Section("Preview") {
                    HStack {
                        LEDDot(indicator: handoff.capsLock)
                        Text("Plays the confirmation on the keyboard and on this dot.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Preview") {
                            handoff.capsLock.diagnose { ok in
                                if ok { handoff.capsLock.playConnected() }
                            }
                        }
                        .disabled(!granted)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .onReceive(tick) { _ in granted = CapsLockIndicator.inputMonitoringGranted }
    }
}

/// On-screen twin of the Caps Lock LED.
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

// MARK: - Advanced

private struct AdvancedSettings: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var handoff: HandoffCoordinator
    @EnvironmentObject private var bluetooth: BluetoothController
    @EnvironmentObject private var peers: PeerService

    var body: some View {
        Form {
            Section("About") {
                LabeledContent("Version", value: AppInfo.version)
                LabeledContent("This Mac", value: settings.thisMacName)
                LabeledContent("Listening", value: peers.listening ? "Yes" : "No")
                Button("Run setup again…") { OnboardingWindow.show() }
            }

            Section("Devices") {
                Text("Magic devices paired with this Mac appear automatically. A device that was last paired with the other Mac can be found with a scan.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack {
                    Button(bluetooth.isScanning ? "Scanning…" : "Scan for nearby devices") { bluetooth.scanNearby() }
                        .disabled(bluetooth.isScanning)
                    Button("Refresh") { bluetooth.refresh(); handoff.ping() }
                }
                ForEach(bluetooth.peripherals) { p in
                    HStack {
                        Image(systemName: p.kind.symbol).frame(width: 20)
                        Text(p.name)
                        Spacer()
                        Text(p.state.label).font(.caption).foregroundStyle(.secondary)
                        Button("Forget") { bluetooth.forget(p.id) }.controlSize(.small)
                    }
                }
            }

            Section("Experimental") {
                Picker("Caps Lock LED method", selection: $settings.capsLockLEDMethod) {
                    ForEach(CapsLockIndicator.Method.allCases, id: \.rawValue) { m in
                        Text(m.label).tag(m.rawValue)
                    }
                }
                Toggle("Keep the pairing on both Macs", isOn: $settings.keepBonds)
                Text("Off (recommended): releasing forgets the device here and the other Mac pairs it fresh. On: only the link is closed; a Magic device that still considers itself owned refuses to pair with the other Mac.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Log") {
                LogPanel(lines: bluetooth.log, onClear: bluetooth.clearLog)
                Text("Also written to ~/Library/Logs/Magic Handoff.log")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .formStyle(.grouped)
    }
}

enum AppInfo {
    static let version: String = {
        let v = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let b = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        return "\(v) (\(b))"
    }()
}

private struct LogPanel: View {
    let lines: [String]
    let onClear: () -> Void
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Spacer()
                Button(copied ? "Copied" : "Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(lines.joined(separator: "\n"), forType: .string)
                    copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
                }
                Button("Clear", action: onClear)
            }
            .controlSize(.small)
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
                .frame(height: 160)
                .onChange(of: lines.count) { _, n in
                    if n > 0 { proxy.scrollTo(n - 1, anchor: .bottom) }
                }
            }
            .background(Color(nsColor: .textBackgroundColor).opacity(0.5))
            .clipShape(RoundedRectangle(cornerRadius: 6))
        }
    }
}
