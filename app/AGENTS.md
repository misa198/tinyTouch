# TinyTouch

- Target: native macOS menu-bar app; minimum macOS 13.
- Firmware flashing may use only the vendored, revision-pinned esp-serial-flasher dependency. Protocol 6 setup may provision PIV and change HID/PIV mode.
- Do not add dependencies when Foundation, AppKit, IOKit, Security, CryptoKit, or CommonCrypto cover the need.
- Preserve protocol compatibility with HID firmware versions 1 and 2.
- Keep credentials in the macOS Keychain; never log or persist plaintext passwords or pairing keys outside it.
- Run shell commands through `rtk`.

## Verify

```sh
rtk swift test
rtk xcodebuild -project TinyTouch.xcodeproj -scheme TinyTouch \
  -configuration Debug -derivedDataPath /private/tmp/TinyTouchDerived \
  CODE_SIGNING_ALLOWED=NO build
rtk git diff --check
```
