import SwiftUI

@main
struct MagicHandoffApp: App {
    @StateObject private var settings: AppSettings
    @StateObject private var bluetooth: BluetoothController
    @StateObject private var handoff: HandoffCoordinator

    init() {
        let settings = AppSettings.shared
        let bluetooth = BluetoothController()
        let handoff = HandoffCoordinator(bluetooth: bluetooth, settings: settings)
        _settings = StateObject(wrappedValue: settings)
        _bluetooth = StateObject(wrappedValue: bluetooth)
        _handoff = StateObject(wrappedValue: handoff)
    }

    var body: some Scene {
        MenuBarExtra {
            MenuContentView()
                .environmentObject(bluetooth)
                .environmentObject(handoff)
                .environmentObject(settings)
                .environmentObject(handoff.peers)
        } label: {
            MenuBarLabel(allConnected: bluetooth.allConnected)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .environmentObject(settings)
                .environmentObject(handoff)
                .environmentObject(handoff.peers)
        }
    }
}


/// The menu bar image, redrawn when the connection state or the appearance changes.
private struct MenuBarLabel: View {
    let allConnected: Bool
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Image(nsImage: MenuIcon.image(allConnected: allConnected, dark: colorScheme == .dark))
    }
}
