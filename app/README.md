# TinyTouch for macOS

TinyTouch is a native macOS menu-bar app for a tinyTouch fingerprint device. It replaces the Python helper from the [original tinyTouch repository](https://github.com/zimengxiong/tinytouch) while keeping HID credentials in the macOS Keychain.

## Requirements

- macOS 13 or later
- Xcode with the macOS SDK
- A tinyTouch device running HID firmware

## What it does

- Detects connected tinyTouch devices and shows their status.
- Configures fingerprint-backed HID typing and stores credentials in Keychain.
- Supports legacy HID protocols 1–5 and protocol 6, including multiple trusted Macs.
- Runs from the menu bar, observes CLI leases, heartbeats/reconnects after sleep or USB changes, and can launch at login.
- Maps passwords for the current keyboard layout and writes redacted, exportable diagnostics.
- Detects the legacy helper so both apps do not compete for the serial port.

## Build and run

Open `TinyTouch.xcodeproj` in Xcode, select the **TinyTouch** scheme, and run it.

The app normally lives only in the menu bar. Choose **Open TinyTouch** to show its window; the Dock icon appears while that window is open and disappears when it closes.

## Test

From this directory:

```sh
swift test
```

For a clean unsigned Debug build:

```sh
xcodebuild -project TinyTouch.xcodeproj -scheme TinyTouch \
  -configuration Debug -derivedDataPath /tmp/TinyTouchDerived \
  CODE_SIGNING_ALLOWED=NO build
```
