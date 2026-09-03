# TinyTouch for macOS

TinyTouch is a native macOS menu-bar app for a tinyTouch fingerprint device. It replaces the Python helper from the [original tinyTouch repository](https://github.com/zimengxiong/tinytouch) while keeping HID credentials in the macOS Keychain.

## Requirements

- macOS 13 or later
- Xcode with the macOS SDK
- A tinyTouch device running compatible HID firmware or unified protocol 6 firmware

## What it does

- Detects connected tinyTouch devices and shows their status.
- Configures fingerprint-backed HID typing and stores credentials in Keychain.
- Replaces `tinytouch setup` with an automatic HID/PIV setup wizard for factory-default protocol 6 devices; the CLI remains available for automation and recovery.
- Supports legacy HID protocols 1–5 and protocol 6, including multiple trusted Macs.
- Factory-resets protocol 6 devices and removes their matching local credentials.
- Installs reviewed firmware releases with data-preserving protocol 6 OTA or a confirmed ESP32-S3 factory flash.
- Runs from the menu bar, observes CLI leases, heartbeats/reconnects after sleep or USB changes, and can launch at login.
- Accepts only runtime devices branded `misa198` / `misa198 tinyTouch` with a `MISA198-TT-` serial; generic ESP32-S3 ROM mode remains available for recovery flashing.
- Maps passwords for the current keyboard layout and writes redacted, exportable diagnostics under the isolated `misa198.TinyTouch` namespace.
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
