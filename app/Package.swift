// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "TinyTouchCore",
    platforms: [.macOS(.v13)],
    products: [.library(name: "TinyTouchCore", targets: ["TinyTouchCore"])],
    targets: [
        .target(
            name: "CSerialFlasher",
            path: "TinyTouch/Vendor/ESPSerialFlasher",
            exclude: ["LICENSE", "UPSTREAM.md"],
            sources: ["src"],
            publicHeadersPath: "include",
            cSettings: [
                .headerSearchPath("private_include"),
                .define("SERIAL_FLASHER_LOG_LEVEL", to: "0"),
                .define("SERIAL_FLASHER_RESET_HOLD_TIME_MS", to: "100"),
                .define("SERIAL_FLASHER_BOOT_HOLD_TIME_MS", to: "50"),
                .define("SERIAL_FLASHER_WRITE_BLOCK_RETRIES", to: "3"),
                .define("SERIAL_FLASHER_RESET_INVERT", to: "false"),
                .define("SERIAL_FLASHER_BOOT_INVERT", to: "false"),
            ]
        ),
        .target(
            name: "TinyTouchCore",
            dependencies: ["CSerialFlasher"],
            path: "TinyTouch",
            exclude: ["AppState.swift", "ContentView.swift", "TinyTouchApp.swift", "TinyTouch-Bridging-Header.h", "Assets.xcassets", "Vendor"],
            sources: ["HIDProtocol.swift", "DeviceServices.swift", "FirmwareSupport.swift"]
        ),
        .testTarget(name: "TinyTouchCoreTests", dependencies: ["TinyTouchCore"], path: "TinyTouchTests")
    ]
)
