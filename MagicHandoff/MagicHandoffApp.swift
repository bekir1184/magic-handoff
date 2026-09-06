import SwiftUI
import AppKit

@main
struct MagicHandoffApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    private let container = AppContainer.shared
    @ObservedObject private var bluetooth: BluetoothController

    init() {
        bluetooth = AppContainer.shared.bluetooth
    }

    var body: some Scene {
        MenuBarExtra {
            MenuContentView()
                .environmentObject(container.bluetooth)
                .environmentObject(container.handoff)
                .environmentObject(container.settings)
                .environmentObject(container.handoff.peers)
        } label: {
            MenuBarLabel(allConnected: bluetooth.allConnected)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .environmentObject(container.settings)
                .environmentObject(container.handoff)
                .environmentObject(container.handoff.peers)
                .environmentObject(container.bluetooth)
        }
    }
}

/// Starts the services once setup is done, or shows the setup window first.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        let container = AppContainer.shared
        if container.settings.onboardingCompleted {
            container.handoff.startServices()
        } else {
            OnboardingWindow.show()
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
