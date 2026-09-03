// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "TinyTouchCore",
    platforms: [.macOS(.v13)],
    products: [.library(name: "TinyTouchCore", targets: ["TinyTouchCore"])],
    targets: [
        .target(
            name: "TinyTouchCore",
            path: "TinyTouch",
            exclude: ["AppState.swift", "ContentView.swift", "TinyTouchApp.swift", "Assets.xcassets"],
            sources: ["HIDProtocol.swift", "DeviceServices.swift"]
        ),
        .testTarget(name: "TinyTouchCoreTests", dependencies: ["TinyTouchCore"], path: "TinyTouchTests")
    ]
)
