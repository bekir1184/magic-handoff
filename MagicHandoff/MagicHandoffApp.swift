import SwiftUI

@main
struct MagicHandoffApp: App {
    @StateObject private var bluetooth = BluetoothController()

    var body: some Scene {
        MenuBarExtra {
            MenuContentView()
                .environmentObject(bluetooth)
        } label: {
            Image(systemName: bluetooth.anyConnected ? "keyboard.fill" : "keyboard")
        }
        .menuBarExtraStyle(.window)
    }
}
