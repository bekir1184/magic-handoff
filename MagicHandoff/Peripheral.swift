import Foundation

/// Snapshot of a Bluetooth peripheral as shown in the UI.
struct Peripheral: Identifiable, Equatable {
    enum Kind: String {
        case keyboard, trackpad, mouse, other

        var symbol: String {
            switch self {
            case .keyboard: return "keyboard"
            case .trackpad: return "rectangle.and.hand.point.up.left"
            case .mouse: return "computermouse"
            case .other: return "dot.radiowaves.left.and.right"
            }
        }
    }

    enum State: Equatable {
        case connected
        case disconnected
        case releasing
        case taking(String)   // sub-step description ("Connecting…", "Pairing…")
        case failed(String)

        var label: String {
            switch self {
            case .connected: return "Connected"
            case .disconnected: return "Not connected"
            case .releasing: return "Releasing…"
            case .taking(let step): return step
            case .failed(let why): return "Error: \(why)"
            }
        }

        var isBusy: Bool {
            switch self {
            case .releasing, .taking: return true
            default: return false
            }
        }
    }

    /// Bluetooth address, e.g. "1c-1d-d3-7a-11-f1". Used as the stable identity.
    let id: String
    var name: String
    var kind: Kind
    var isPaired: Bool
    var state: State
}
