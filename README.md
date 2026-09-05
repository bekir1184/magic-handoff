# Magic Handoff

A macOS menu bar app that moves your Magic Keyboard, Magic Trackpad and Magic Mouse between two Macs with one click. No more plugging in a cable or re-pairing by hand every time you switch machines.

## Status

**Phase 1 – done.** Single-Mac Bluetooth layer: list paired Magic devices, *Release* removes the bond, *Take* reconnects or pairs from scratch, *Scan nearby* discovers unpaired devices. Verified on macOS 26.5 without any system dialog.

**Phase 2 – in progress.** Two Macs find each other over Bonjour and talk over TLS with a pre-shared key derived from a pairing code you type on both. *Send* releases a device here and asks the other Mac to take it; *Take* asks the other Mac to let go and connects it here. Optional automatic handoff when the Mac goes to sleep.

**Later:** global hotkey, take-back on wake, menu bar polish, signed builds.

## How it works

Apple's Magic devices connect to a single Mac at a time. The app does in software what the USB cable trick does automatically:

1. The Mac giving the device up removes the bond through `IOBluetoothDevice`'s private `-remove` selector (the same thing "Forget This Device" does in System Settings).
2. The Mac taking the device connects with `openConnection()` if it is still bonded, otherwise pairs from scratch with `IOBluetoothDevicePair`.

Any process that touches the Bluetooth API must declare `NSBluetoothAlwaysUsageDescription` in its Info.plist, otherwise TCC terminates it. That is why this is an app bundle rather than a command-line tool.

## Building

Requirements: macOS 14+, Xcode 26, [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`).

```bash
scripts/build.sh --run
```

Or run `xcodegen generate` and open `MagicHandoff.xcodeproj` in Xcode. macOS asks for Bluetooth and Local Network access on first launch.

Install the app on both Macs. Each Mac shows a pairing code in the menu bar popover on first launch; type one Mac's code into the other and the two connect automatically. Until then the popover only shows the setup steps.

Keep the checkout outside iCloud Drive (for example `~/Developer`): file-provider extended attributes on synced folders break code signing.

## Warning

*Release* really removes the bond. Do not use it on a desktop Mac where the device is your only input; the prototype is meant to be tested on a MacBook with its built-in keyboard and trackpad.

## License

MIT
