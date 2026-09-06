import Foundation

/// The app's long-lived objects, shared by the SwiftUI scenes, the app
/// delegate and the setup window.
final class AppContainer {
    static let shared = AppContainer()

    let settings: AppSettings
    let bluetooth: BluetoothController
    let handoff: HandoffCoordinator

    private init() {
        settings = AppSettings.shared
        bluetooth = BluetoothController()
        handoff = HandoffCoordinator(bluetooth: bluetooth, settings: settings)
    }
}
