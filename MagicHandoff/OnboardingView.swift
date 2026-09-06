import SwiftUI
import AppKit
import CoreBluetooth

/// Hosts the guided setup in its own window (the app has no main window).
enum OnboardingWindow {
    private static var controller: NSWindowController?

    static func show(startingAt step: OnboardingView.Step = .welcome) {
        if controller == nil {
            let container = AppContainer.shared
            let root = OnboardingView(initialStep: step)
                .environmentObject(container.settings)
                .environmentObject(container.bluetooth)
                .environmentObject(container.handoff)
                .environmentObject(container.handoff.peers)
            let hosting = NSHostingController(rootView: root)
            let window = NSWindow(contentViewController: hosting)
            window.title = "Magic Handoff Setup"
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            window.setContentSize(NSSize(width: 520, height: 500))
            window.center()
            controller = NSWindowController(window: window)
        }
        NSApp.activate(ignoringOtherApps: true)
        controller?.showWindow(nil)
        controller?.window?.makeKeyAndOrderFront(nil)
    }

    static func close() {
        controller?.close()
        controller = nil
    }
}

struct OnboardingView: View {
    enum Step: Int, CaseIterable { case welcome, bluetooth, network, otherMac, done }

    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var bluetooth: BluetoothController
    @EnvironmentObject private var handoff: HandoffCoordinator
    @EnvironmentObject private var peers: PeerService

    @State private var step: Step
    @State private var bluetoothAuth = BluetoothController.authorization

    private let tick = Timer.publish(every: 0.5, on: .main, in: .common).autoconnect()

    init(initialStep: Step = .welcome) {
        // Resume where a relaunch (e.g. for Input Monitoring) interrupted the setup.
        let settings = AppSettings.shared
        if initialStep == .welcome, !settings.onboardingCompleted,
           let saved = Step(rawValue: settings.onboardingStep), saved.rawValue > Step.welcome.rawValue {
            _step = State(initialValue: saved)
        } else {
            _step = State(initialValue: initialStep)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding(28)
            Divider()
            footer.padding(16)
        }
        .frame(width: 520, height: 500)
        .onReceive(tick) { _ in
            bluetoothAuth = BluetoothController.authorization
        }
        .onAppear { servicesForResume() }
        .onChange(of: step) { _, new in
            if !settings.onboardingCompleted { settings.onboardingStep = new.rawValue }
            servicesForResume()
        }
    }

    // MARK: - Steps

    @ViewBuilder
    private var content: some View {
        switch step {
        case .welcome: welcome
        case .bluetooth: bluetoothStep
        case .network: networkStep
        case .otherMac: otherMacStep
        case .done: doneStep
        }
    }

    private var welcome: some View {
        VStack(alignment: .leading, spacing: 14) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 72, height: 72)
            Text("Welcome to Magic Handoff").font(.title.weight(.semibold))
            Text("Move your Magic Keyboard, Trackpad and Mouse between two Macs with one keystroke. No cables, no re-pairing by hand.")
            Text("Setup takes about a minute. It asks for a few permissions one at a time and explains what each one is for. Install Magic Handoff on your other Mac as well.")
                .foregroundStyle(.secondary)
        }
    }

    private var bluetoothStep: some View {
        StepPage(
            title: "Bluetooth",
            why: "Magic Handoff releases and connects your devices over Bluetooth. This is the one permission the app cannot work without.",
            without: "Without it the app can do nothing."
        ) {
            switch bluetoothAuth {
            case .allowedAlways:
                StatusRow(ok: true, text: "Bluetooth access granted")
            case .denied, .restricted:
                StatusRow(ok: false, text: "Bluetooth access is off for Magic Handoff")
                Button("Open Privacy & Security…") {
                    open("x-apple.systempreferences:com.apple.preference.security?Privacy_Bluetooth")
                }
            default:
                Button("Allow Bluetooth access") { bluetooth.start() }
                    .keyboardShortcut(.defaultAction)
                Text("macOS will ask; choose Allow.").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var networkStep: some View {
        StepPage(
            title: "Local Network",
            why: "The two Macs find each other on your Wi-Fi or wired network and coordinate every handoff over an encrypted connection. Nothing leaves your network.",
            without: "Without it Magic Handoff cannot see your other Mac; you could only connect or release devices on this Mac by hand."
        ) {
            if !peers.started {
                Button("Allow Local Network access") { peers.start() }
                    .keyboardShortcut(.defaultAction)
                Text("macOS will ask; choose Allow.").font(.caption).foregroundStyle(.secondary)
            } else {
                switch peers.localNetwork {
                case .allowed:
                    StatusRow(ok: true, text: peers.peers.isEmpty ? "Local Network access granted" : "Local Network access granted · \(peers.peers.count) Mac found")
                case .denied:
                    StatusRow(ok: false, text: "Local Network access is off for Magic Handoff")
                    Button("Open Privacy & Security…") {
                        open("x-apple.systempreferences:com.apple.preference.security?Privacy_LocalNetwork")
                    }
                case .unknown:
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Waiting for your answer…").foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private var otherMacStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Connect your other Mac").font(.title2.weight(.semibold))
            if handoff.isSetUp {
                StatusRow(ok: true, text: "Connected to \(handoff.peerName)")
            } else {
                SetupView()
            }
        }
    }

    private var doneStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("You're all set").font(.title2.weight(.semibold))
            let mine = settings.thisMacHotkey
            let other = mine == 1 ? 2 : 1
            Text("Press ⌘⇧\(other) on the keyboard to send everything to your other Mac, and ⌘⇧\(mine) to bring it back. Set the other Mac to ⌘⇧\(other) in its Settings.")
            Text("Magic Handoff lives in the menu bar: the dot in its icon turns green when every device is on this Mac. Settings has the hotkeys, sleep behaviour and diagnostics.")
                .foregroundStyle(.secondary)
            Text("Optional: Settings → Keyboard Light can flash the keyboard's Caps Lock light as devices arrive. It needs an extra permission, so it is off unless you turn it on.")
                .foregroundStyle(.secondary)
            if !handoff.isSetUp {
                Text("Your other Mac isn't connected yet. Open Settings whenever it's ready; the code is there.")
                    .foregroundStyle(.orange)
            }
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            if step != .welcome && step != .done {
                Button("Back") { step = Step(rawValue: step.rawValue - 1) ?? .welcome }
            }
            Spacer()
            switch step {
            case .welcome:
                Button("Get started") { step = .bluetooth }.keyboardShortcut(.defaultAction)
            case .bluetooth:
                Button("Continue") { step = .network }
                    .disabled(bluetoothAuth != .allowedAlways)
            case .network:
                Button(peers.localNetwork == .allowed ? "Continue" : "Continue anyway") { step = .otherMac }
                    .disabled(!peers.started)
            case .otherMac:
                Button(handoff.isSetUp ? "Continue" : "Do this later") { step = .done }
            case .done:
                Button("Finish") { finish() }.keyboardShortcut(.defaultAction)
            }
        }
        .controlSize(.large)
    }

    /// Past the permission steps, the services should be running (they only
    /// prompt when a permission has not been decided yet).
    private func servicesForResume() {
        if step.rawValue > Step.bluetooth.rawValue, bluetoothAuth == .allowedAlways { bluetooth.start() }
        if step.rawValue > Step.network.rawValue { peers.start() }
    }

    private func finish() {
        settings.onboardingStep = 0
        settings.onboardingCompleted = true
        handoff.startServices()
        OnboardingWindow.close()
    }

    private func open(_ url: String) {
        if let u = URL(string: url) { NSWorkspace.shared.open(u) }
    }
}

// MARK: - Pieces

private struct StepPage<Content: View>: View {
    let title: String
    let why: String
    let without: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.title2.weight(.semibold))
            Text(why)
            Text(without).foregroundStyle(.secondary)
            Divider().padding(.vertical, 4)
            content()
        }
    }
}

struct StatusRow: View {
    let ok: Bool
    let text: String

    var body: some View {
        Label(text, systemImage: ok ? "checkmark.circle.fill" : "xmark.circle.fill")
            .foregroundStyle(ok ? Color.green : Color.red)
    }
}
