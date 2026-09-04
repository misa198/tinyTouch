import CryptoKit
import CSerialFlasher
import XCTest
@testable import TinyTouchCore

final class FirmwareSupportTests: XCTestCase {
    private let manifestURL = URL(string: "https://github.com/misa198/tinyTouch/releases/download/v0.8.4/release-manifest.json")!

    private func channel(_ releases: [[String: String]]? = nil) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["schema": 1, "releases": releases ?? [[
            "version": "0.8.4", "minAppVersion": "1.0.0", "maxAppVersionExclusive": "2.0.0",
            "manifest": manifestURL.absoluteString,
        ]]])
    }

    private func manifest(version: String = "0.8.4", checksum: String = String(repeating: "a", count: 64)) throws -> Data {
        let asset: [String: Any] = ["file": "tiny_touch_unified.bin", "size": 4, "sha256": checksum]
        return try JSONSerialization.data(withJSONObject: [
            "product": "misa198.tinytouch.v1", "version": version, "protocol": 6,
            "boards": ["esp32s3-super-mini", "seeed-xiao-esp32s3"],
            "ota": asset,
            "firmware": ["factory": ["version": version,
                "fullImage": ["file": "tiny_touch_factory_full.bin", "size": 4, "sha256": checksum]]],
        ])
    }

    func testSemVerNormalizationExclusiveUpperBoundAndLatestSelection() throws {
        XCTAssertEqual(try SemanticVersion("1.0", normalizeAppVersion: true).description, "1.0.0")
        let releases = [
            ["version": "0.8.3", "minAppVersion": "1.0.0", "maxAppVersionExclusive": "2.0.0", "manifest": "https://example.com/old.json"],
            ["version": "0.8.4", "minAppVersion": "1.0.0", "maxAppVersionExclusive": "2.0.0", "manifest": manifestURL.absoluteString],
        ]
        XCTAssertEqual(try FirmwareChannel.decode(channel(releases), appVersion: "1.0").version, "0.8.4")
        XCTAssertThrowsError(try FirmwareChannel.decode(channel(releases), appVersion: "2.0.0"))
    }

    func testChannelAndManifestFailClosed() throws {
        let duplicate = Array(repeating: ["version": "0.8.4", "minAppVersion": "1.0.0",
            "maxAppVersionExclusive": "2.0.0", "manifest": manifestURL.absoluteString], count: 2)
        XCTAssertThrowsError(try FirmwareChannel.decode(channel(duplicate), appVersion: "1.0"))
        let identity = DeviceIdentity(id: "TT-X", port: "/dev/test")
        XCTAssertThrowsError(try FirmwareSupport.update(channelData: channel(), manifestData: manifest(version: "0.8.3"),
            manifestURL: manifestURL, appVersion: "1.0", identity: identity, status: nil))
    }

    func testCurrentFirmwareIsNotAnUpdateFailure() throws {
        let status = try DeviceStatus(line: "OK STATUS protocol=6 firmware=0.8.4 mode=hid sensor=ready fingerprints=1 hosts=1")
        XCTAssertThrowsError(try FirmwareSupport.update(channelData: channel(), manifestData: manifest(), manifestURL: manifestURL,
            appVersion: "1.0", identity: .init(id: "TT-X", port: "/dev/test"), status: status)) {
            guard case FirmwareError.noUpdate = $0 else { return XCTFail("Expected noUpdate, got \($0)") }
        }
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        XCTAssertTrue(try String(contentsOf: root.appendingPathComponent("TinyTouch/AppState.swift")).contains("catch FirmwareError.noUpdate"))
    }

    func testChecksumAndStrategySelection() throws {
        let bytes = Data("test".utf8)
        let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        try FirmwareSupport.verify(bytes, asset: FirmwareAsset(file: "firmware.bin", size: 4, sha256: digest))
        XCTAssertThrowsError(try FirmwareSupport.verify(bytes, asset: FirmwareAsset(file: "firmware.bin", size: 5, sha256: digest)))
        let protocol6 = try DeviceStatus(line: "OK STATUS protocol=6 firmware=0.8.3 mode=hid sensor=ready fingerprints=1 hosts=1")
        XCTAssertEqual(FirmwareSupport.strategy(for: .init(id: "TT-X", port: "/dev/test"), status: protocol6), .ota)
        XCTAssertEqual(FirmwareSupport.strategy(for: .init(id: "ROM-X", port: "/dev/test", kind: .rom), status: nil), .factory)
    }

    func testOTASequenceAndOffsets() async throws {
        actor Commands { var values: [String] = []; func add(_ value: String) { values.append(value) } }
        let commands = Commands(), image = Data(repeating: 7, count: 721)
        try await FirmwareSupport.ota(image: image, digest: String(repeating: "a", count: 64), command: { command, _ in
            await commands.add(command)
            if command == "AUTH" { return ["OK AUTH"] }
            if command.hasPrefix("OTA BEGIN") { return ["OK OTA BEGIN next=0"] }
            if command.hasPrefix("OTA WRITE") {
                let words = command.split(separator: " ")
                let offset = Int(words[3])!, count = Data(base64Encoded: String(words[4]))!.count
                return ["OK OTA WRITE next=\(offset + count)"]
            }
            return ["OK OTA STAGED power_cycle=required"]
        }, progress: { _ in })
        let values = await commands.values
        XCTAssertEqual(values.first, "AUTH")
        XCTAssertTrue(values[1].hasPrefix("OTA BEGIN "))
        XCTAssertEqual(values.filter { $0.hasPrefix("OTA WRITE") }.count, 3)
        XCTAssertTrue(values.last!.hasPrefix("OTA COMMIT"))
    }

    func testUSBKindsAndPhysicalLocationRemainStableAcrossPortChange() {
        let first = SerialDiscovery.identity(vendorID: 0x303A, productID: 0x1001, serial: nil,
            locationID: 0x1234, port: "/dev/cu.usbmodem1", advanced: false)
        let second = SerialDiscovery.identity(vendorID: 0x303A, productID: 0x1001, serial: nil,
            locationID: 0x1234, port: "/dev/cu.usbmodem9", advanced: false)
        XCTAssertEqual(first?.id, second?.id); XCTAssertNotEqual(first?.port, second?.port)
        XCTAssertEqual(first?.kind, .rom)
        XCTAssertNil(SerialDiscovery.identity(vendorID: 0x10C4, productID: 0xEA60, serial: "A",
            locationID: 1, port: "/dev/cu.usbserial", advanced: false))
        XCTAssertEqual(SerialDiscovery.identity(vendorID: 0x10C4, productID: 0xEA60, serial: "A",
            locationID: 1, port: "/dev/cu.usbserial", advanced: true)?.kind, .serialAdapter)
    }

    func testFlashOnboardingIgnoresBriefROMDiscoveryGaps() {
        var visibility = FlashOnboardingVisibility(), now = Date(timeIntervalSince1970: 0)
        visibility.update(hasROM: true, now: now); XCTAssertTrue(visibility.visible)
        now.addTimeInterval(1); visibility.update(hasROM: false, now: now); XCTAssertTrue(visibility.visible)
        now.addTimeInterval(1); visibility.update(hasROM: true, now: now); XCTAssertTrue(visibility.visible)
        now.addTimeInterval(2); visibility.update(hasROM: false, now: now)
        now.addTimeInterval(2); visibility.update(hasROM: false, now: now); XCTAssertFalse(visibility.visible)
    }

    func testNewBoardResetFailureRetriesResetInsteadOfFlashing() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: root.appendingPathComponent("TinyTouch/FirmwareViews.swift"))
        XCTAssertTrue(source.contains("Button(\"Retry Factory Reset\") { app.retryNewBoardFactoryReset() }"))
        let state = try String(contentsOf: root.appendingPathComponent("TinyTouch/AppState.swift"))
        XCTAssertTrue(state.contains("manager.reconnect(id)"))
        XCTAssertTrue(state.contains("let status = try await waitForStatus(id: id)"))
        XCTAssertTrue(state.contains("showPrompt(\"PROMPT TOUCH\", deviceID: id)"))
    }

    func testNewBoardFlashPersistsItsPhysicalLocationUntilResetSucceeds() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: root.appendingPathComponent("TinyTouch/AppState.swift"))
        XCTAssertTrue(source.contains("newBoardFlashLocationID = locationID; defaults.set(locationID, forKey: \"newBoardFlashLocationID\")"))
        XCTAssertTrue(source.contains("defaults.removeObject(forKey: \"newBoardFlashLocationID\")"))
    }

    func testOTACompletesOnlyAfterReconnectedVersionIsVerified() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: root.appendingPathComponent("TinyTouch/AppState.swift"))
        XCTAssertTrue(source.contains("pendingOTAVerification"))
        XCTAssertTrue(source.contains("current.firmwareVersion == pending.version"))
        XCTAssertTrue(source.contains("firmware.phase = .complete"))
    }

    func testCBridgeRejectsMissingImageBeforeOpeningSerial() {
        var error = [CChar](repeating: 0, count: 128)
        XCTAssertEqual(tt_flash_factory("/dev/does-not-exist", "/does-not-exist", false, nil, nil, &error, error.count), Int32(TT_FLASH_IO))
    }
}
