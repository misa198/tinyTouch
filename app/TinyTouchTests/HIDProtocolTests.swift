import CryptoKit
import Darwin
import Foundation
import XCTest
@testable import TinyTouchCore

final class HIDProtocolTests: XCTestCase {
    private let key = Data(0..<32)
    private var temporaryDirectories: [URL] = []

    override func tearDown() {
        temporaryDirectories.forEach { try? FileManager.default.removeItem(at: $0) }
        temporaryDirectories.removeAll()
        super.tearDown()
    }

    func testProtocolGoldenCasesAndPythonReplayJSON() throws {
        let aesKey = Data(strictHex: "603deb1015ca71be2b73aef0857d77811f352c073b6108d72d9810a30914dff4")!
        let iv = Data(strictHex: "f0f1f2f3f4f5f6f7f8f9fafbfcfdfeff")!
        let plaintext = Data(strictHex: "6bc1bee22e409f96e93d7e117393172a")!
        XCTAssertEqual(try HIDProtocol.aesCTR(key: aesKey, iv: iv, input: plaintext).hex,
                       "601ec313775789a5b7a7f504bbf3d228")
        XCTAssertEqual(try HIDProtocol.keyID(key), "630dcd2966c43366")
        XCTAssertEqual(KeychainStore.passwordService, "tinyTouch")
        XCTAssertEqual(KeychainStore.pairingService, "tinyTouch-pairing")
        XCTAssertEqual(DeviceIdentity.normalize("b8f862fb478c"), "B8F862FB478C")

        var state = ReplayState()
        for index in 0..<300 { try state.accept(String(format: "%032x", index)) }
        XCTAssertEqual(state.seenNonces.count, 256)
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let pythonJSON = #"{"seen_nonces":["000000000000000000000000000000aa"]}"#
        try Data(pythonJSON.utf8).write(to: directory.appendingPathComponent("state-PYTHON.json"))
        XCTAssertEqual(ReplayStateStore(directory: directory).load(deviceID: "python").seenNonces,
                       ["000000000000000000000000000000aa"])
    }

    func testRuntimeUSBMatcher() {
        XCTAssertEqual(SerialDiscovery.runtimeIdentity(vendorID: 0x303A, productID: 0x4001,
            serial: "tt-demo", port: "/dev/cu.usbmodem1")?.id, "TT-DEMO")
        XCTAssertNil(SerialDiscovery.runtimeIdentity(vendorID: 0x1234, productID: 0x4001, serial: "TT-A", port: "p"))
        XCTAssertNil(SerialDiscovery.runtimeIdentity(vendorID: 0x303A, productID: 0x0009, serial: "TT-A", port: "p"))
        XCTAssertNil(SerialDiscovery.runtimeIdentity(vendorID: 0x303A, productID: 0x4001, serial: nil, port: "p"))
        XCTAssertNil(SerialDiscovery.runtimeIdentity(vendorID: 0x303A, productID: 0x4001, serial: "other", port: "p"))
    }

    func testKeychainStatusMappingAndReconnectPolicy() throws {
        XCTAssertNil(try KeychainStore.result(status: errSecItemNotFound, data: nil))
        XCTAssertThrowsError(try KeychainStore.result(status: errSecInteractionNotAllowed, data: nil)) {
            guard case .keychain(errSecInteractionNotAllowed) = $0 as? DeviceError else { return XCTFail("Expected Keychain error") }
        }
        XCTAssertFalse(DeviceError.keychain(errSecAuthFailed).blocksReconnect)
        XCTAssertTrue(DeviceError.busy("port").blocksReconnect)
        let now = Date(), deadline = now.addingTimeInterval(BackoffPolicy().delay(failures: 1, random: 0.5))
        XCTAssertFalse(DeviceManager.canReconnect(deadline: deadline, now: now))
        XCTAssertTrue(DeviceManager.canReconnect(deadline: deadline, now: deadline))
    }

    @MainActor
    func testRetryAndWakeClearReconnectDeadlines() {
        let manager = DeviceManager(discover: { [] })
        manager.retryDeadlines["retry"] = .distantFuture
        manager.retry("retry")
        XCTAssertNil(manager.retryDeadlines["retry"])
        manager.retryDeadlines["wake"] = .distantFuture
        manager.reconnectAfterWake()
        XCTAssertTrue(manager.retryDeadlines.isEmpty)
    }

    func testEVAndEV2GoldenResponsesDecrypt() throws {
        let nonce = String(repeating: "01", count: 16)
        let state = ReplayState()
        let ev = "EV \(nonce) 7 1 1 \(hmac("EV|\(nonce)|7|1|1"))"
        try assertPassword(try XCTUnwrap(HIDProtocol.response(to: ev, passwords: [0: Data("password".utf8)],
            pairingKey: key, state: state, iv: Data(repeating: 2, count: 16))).line, expected: "password", key: key)

        let nonce2 = String(repeating: "03", count: 16), id = try HIDProtocol.keyID(key)
        let ev2 = "EV2 \(nonce2) 8 1 77 deadbeefdeadbeef:\(String(repeating: "0", count: 64)) \(id):\(hmac("EV2|\(id)|\(nonce2)|8|1|77"))"
        try assertPassword(try XCTUnwrap(HIDProtocol.response(to: ev2, passwords: [0: Data("secret".utf8)],
            pairingKey: key, state: state, iv: Data(repeating: 4, count: 16))).line, expected: "secret", key: key)
    }

    func testMalformedBadMACReplayAndParsers() throws {
        var state = ReplayState(); let nonce = String(repeating: "05", count: 16)
        XCTAssertThrowsError(try HIDProtocol.response(to: "EV nope", passwords: [0: Data()], pairingKey: key, state: state))
        XCTAssertThrowsError(try HIDProtocol.response(to: "EV \(nonce) 1 1 1 \(String(repeating: "0", count: 64))",
            passwords: [0: Data()], pairingKey: key, state: state)) { XCTAssertEqual($0 as? HIDProtocolError, .badMAC) }
        let line = "EV \(nonce) 1 1 1 \(hmac("EV|\(nonce)|1|1|1"))"
        _ = try HIDProtocol.response(to: line, passwords: [0: Data()], pairingKey: key, state: state, iv: Data(repeating: 0, count: 16))
        try state.accept(nonce)
        XCTAssertThrowsError(try HIDProtocol.response(to: line, passwords: [0: Data()], pairingKey: key, state: state)) {
            XCTAssertEqual($0 as? HIDProtocolError, .replay)
        }
        let status = try DeviceStatus(line: "OK STATUS firmware_version=1.2 protocol=2 mode=hid sensor=ok fingerprints=3 hid_hosts=2")
        XCTAssertEqual(status.protocolVersion, 2); XCTAssertEqual(status.fingerprintCount, 3)
        let hosts = try HIDHostList(line: "OK HID_KEY_IDS ids=0011223344556677 capacity=8")
        XCTAssertEqual(hosts.ids.count, 1); XCTAssertEqual(hosts.capacity, 8)
    }

    func testProtocolSixDialectStatusAliasesAndUnknownVersion() throws {
        XCTAssertEqual(DeviceDialect(protocolVersion: 1).unlock, "CONFIG_UNLOCK")
        XCTAssertEqual(DeviceDialect(protocolVersion: 5).enroll(slot: 2), "ENROLL 2")
        let current = DeviceDialect(protocolVersion: 6)
        XCTAssertEqual(current.unlock, "AUTH")
        XCTAssertEqual(current.hostList, "HOST LIST")
        XCTAssertEqual(current.hostAdd(id: "id", key: "key"), "HOST ADD id key")
        XCTAssertEqual(current.hostRemove(id: "id"), "HOST REMOVE id")
        XCTAssertEqual(current.enroll(slot: 4), "FINGER ENROLL 4")
        XCTAssertEqual(current.delete(slot: 4), "FINGER DELETE 4")
        XCTAssertEqual(current.clear, "FINGER CLEAR")

        let status = try DeviceStatus(line: "OK STATUS protocol=6 firmware=0.8.3 mode=hid sensor=ready fingerprints=4 hosts=2")
        XCTAssertTrue(status.sensorReady); XCTAssertEqual(status.hidHosts, 2); XCTAssertTrue(status.isCompatible)
        XCTAssertFalse(try DeviceStatus(line: "OK STATUS protocol=7 mode=hid sensor=ok").isCompatible)
        let hosts = try HIDHostList(line: "OK HOST LIST ids=AABBCCDDEEFF0011 capacity=8")
        XCTAssertEqual(hosts.ids, ["aabbccddeeff0011"])
    }

    func testParserBoundsAuthenticatorUniquenessSlotPasswordAndCaseInsensitiveReplay() throws {
        let upperNonce = String(repeating: "AB", count: 16), id = try HIDProtocol.keyID(key)
        let mac = hmac("EV2|\(id)|\(upperNonce)|1|5|2147483647")
        let response = try XCTUnwrap(HIDProtocol.response(
            to: "EV2 \(upperNonce) 1 5 2147483647 \(id.uppercased()):\(mac.uppercased())",
            passwords: [0: Data("default".utf8), 5: Data("slot-five".utf8)], pairingKey: key,
            state: ReplayState(), keyboardMode: .us, iv: Data(repeating: 7, count: 16)))
        XCTAssertEqual(response.nonce, upperNonce.lowercased()); XCTAssertEqual(response.slot, 5)
        try assertPassword(response.line, expected: "slot-five", key: key)

        let replay = ReplayState(seenNonces: [upperNonce.lowercased()])
        XCTAssertThrowsError(try HIDProtocol.response(to: "EV2 \(upperNonce) 1 5 2147483647 \(id):\(mac)",
            passwords: [0: Data()], pairingKey: key, state: replay)) {
            XCTAssertEqual($0 as? HIDProtocolError, .replay)
        }
        let authenticator = "\(id):\(mac)"
        XCTAssertThrowsError(try HIDProtocol.response(to: "EV2 \(upperNonce) 1 5 1 \(authenticator) \(authenticator)",
            passwords: [0: Data()], pairingKey: key, state: ReplayState()))
        let excess = (0..<9).map { String(format: "%016x:", $0) + String(repeating: "0", count: 64) }.joined(separator: " ")
        XCTAssertThrowsError(try HIDProtocol.response(to: "EV2 \(upperNonce) 1 5 1 \(excess)",
            passwords: [0: Data()], pairingKey: key, state: ReplayState()))
        for fields in ["18446744073709551616 1 1", "1 0 1", "1 1 2147483648", "-1 1 1"] {
            XCTAssertThrowsError(try HIDProtocol.response(to: "EV \(upperNonce) \(fields) \(String(repeating: "0", count: 64))",
                passwords: [0: Data()], pairingKey: key, state: ReplayState()))
        }
    }

    func testKeyboardMappingModesAndLimits() throws {
        XCTAssertEqual(try KeyboardMapper.translate(Data("abc".utf8), mode: .us), Data("abc".utf8))
        XCTAssertEqual(try KeyboardMapper.translate(Data("é;".utf8), mode: .auto,
            outputMap: ["é": "2", ";": "<"]), Data("2<".utf8))
        XCTAssertThrowsError(try KeyboardMapper.translate(Data("é".utf8), mode: .us))
        XCTAssertThrowsError(try KeyboardMapper.translate(Data("^".utf8), mode: .auto, outputMap: [:]))
        XCTAssertNoThrow(try KeyboardMapper.translate(Data(repeating: 65, count: 160), mode: .us))
        XCTAssertThrowsError(try KeyboardMapper.translate(Data(repeating: 65, count: 161), mode: .us))
        let store = KeyboardSettingsStore(directory: temporaryDirectory())
        XCTAssertEqual(store.load(deviceID: "tt-demo").keyboardLayout, .auto)
        try store.save(KeyboardSettings(keyboardLayout: .us), deviceID: "tt-demo")
        XCTAssertEqual(store.load(deviceID: "TT-DEMO").keyboardLayout, .us)
    }

    func testFrameDecoderQuarantinesOversizeAndRecoversGluedEvents() {
        var decoder = SerialFrameDecoder(maximum: 8)
        XCTAssertEqual(decoder.feed(Data("EV one".utf8)), [])
        XCTAssertEqual(decoder.feed(Data("\nPONG\n".utf8)).map { String(decoding: $0, as: UTF8.self) }, ["EV one", "PONG"])
        XCTAssertEqual(decoder.feed(Data("123456789EV fake".utf8)), [])
        XCTAssertEqual(decoder.feed(Data(" tail\nOK\n".utf8)).map { String(decoding: $0, as: UTF8.self) }, ["OK"])
        let intact = "EV2 \(String(repeating: "ab", count: 16)) 1 1 1 value"
        XCTAssertEqual(DeviceSession.resynchronizeEvent("EV partial\(intact)"), intact)
    }

    func testNonceCommitsOnlyAfterSuccessfulWrite() throws {
        let directory = temporaryDirectory(), store = ReplayStateStore(directory: directory)
        let response = HIDResponse(line: "PW test\n", nonce: String(repeating: "ab", count: 16), slot: 1)
        var state = ReplayState()
        XCTAssertThrowsError(try HIDProtocol.deliver(response, state: &state, store: store, deviceID: "WRITE-FAIL") { _ in
            throw DeviceError.disconnected
        })
        XCTAssertTrue(state.seenNonces.isEmpty)
        var flushed = false
        try HIDProtocol.deliver(response, state: &state, store: store, deviceID: "WRITE-OK") { _ in flushed = true }
        XCTAssertTrue(flushed); XCTAssertEqual(state.seenNonces, [response.nonce])
        XCTAssertEqual(store.load(deviceID: "WRITE-OK"), state)
    }

    func testBackoffAndMigrationProof() throws {
        let policy = BackoffPolicy(initial: 1, maximum: 8, multiplier: 2, jitter: 0.25)
        XCTAssertEqual(policy.delay(failures: 1, random: 0.5), 1)
        XCTAssertEqual(policy.delay(failures: 2, random: 0.5), 2)
        XCTAssertEqual(policy.delay(failures: 20, random: 0.5), 8)
        XCTAssertEqual(policy.delay(failures: 1, random: 0), 0.75)
        XCTAssertNil(CredentialMigrator.provenSource(destination: "TT-NEW", hostIDs: ["deadbeefdeadbeef"]) { _ in key })
        XCTAssertEqual(CredentialMigrator.provenSource(destination: "TT-NEW", hostIDs: [try HIDProtocol.keyID(key)]) { account in
            account == "tinyTouch" ? key : nil
        }, "tinyTouch")
    }

    func testLeaseValidationAcknowledgementAndStaleCleanup() throws {
        let directory = temporaryDirectory(), observer = LeaseObserver(directory: directory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let live = LeaseRecord(schema: LeaseRecord.schema, pid: getpid(), nonce: String(repeating: "a", count: 32),
                               acquiredAt: Date().timeIntervalSince1970)
        try JSONEncoder().encode(live).write(to: observer.leaseURL)
        XCTAssertEqual(observer.active(), live)
        try observer.acknowledge(live)
        let ack = try JSONSerialization.jsonObject(with: Data(contentsOf: observer.acknowledgementURL)) as? [String: Any]
        XCTAssertEqual(ack?["nonce"] as? String, live.nonce)

        let stale = LeaseRecord(schema: LeaseRecord.schema, pid: getpid(), nonce: live.nonce,
                                acquiredAt: Date().timeIntervalSince1970 - LeaseRecord.maximumAge - 1)
        try JSONEncoder().encode(stale).write(to: observer.leaseURL)
        XCTAssertNil(observer.active()); XCTAssertFalse(FileManager.default.fileExists(atPath: observer.acknowledgementURL.path))
        try Data("invalid".utf8).write(to: observer.leaseURL)
        XCTAssertNil(observer.active())
        let uppercase = LeaseRecord(schema: LeaseRecord.schema, pid: getpid(), nonce: String(repeating: "A", count: 32),
                                    acquiredAt: Date().timeIntervalSince1970)
        try JSONEncoder().encode(uppercase).write(to: observer.leaseURL)
        XCTAssertNil(observer.active())
    }

    func testDiagnosticsExportRedactsSecretFields() throws {
        let original = DiagnosticsStore.directory, directory = temporaryDirectory()
        DiagnosticsStore.directory = directory; defer { DiagnosticsStore.directory = original }
        let secret = "fixture-password-ciphertext-pairing-key"
        DiagnosticsStore.record("test.event", deviceID: "tt-demo",
                                fields: ["reason": "safe", "password": secret, "ciphertext": secret])
        let export = directory.appendingPathComponent("export.json")
        try DiagnosticsStore.export(to: export, devices: [.init(id: "TT-DEMO", port: "/dev/test")],
                                    states: ["background_enabled": "true", "password": secret])
        let value = try String(contentsOf: export, encoding: .utf8)
        XCTAssertFalse(value.contains(secret)); XCTAssertTrue(value.contains("test.event"))
        for _ in 0..<3 {
            try Data(repeating: 0x20, count: DiagnosticsStore.maximumBytes).write(to: DiagnosticsStore.logURL)
            DiagnosticsStore.record("rotation.event")
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent("runtime.jsonl.1").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent("runtime.jsonl.2").path))
    }

    func testLegacyProcessParsingAndFiniteWait() {
        let lsof = "p123\ncpython3\nn/dev/cu.usbmodem1\np456\ncmonitor\nn/dev/cu.usbmodem2\n"
        var owners = LegacyProcessInspector.parseLsof(lsof)
        let ps = LegacyProcessInspector.parsePS("123 /usr/bin/python3 python3 tinytouch_helper.py\n456 /bin/monitor monitor --serial\n")
        for index in owners.indices where ps[owners[index].pid] != nil {
            owners[index].name = ps[owners[index].pid]!.0; owners[index].command = ps[owners[index].pid]!.1
        }
        XCTAssertTrue(owners[0].isLegacyHelper); XCTAssertFalse(owners[1].isLegacyHelper)
        let started = Date()
        XCTAssertEqual(LegacyProcessInspector.waitForRelease(timeout: 0.02) { owners }, owners)
        XCTAssertLessThan(Date().timeIntervalSince(started), 0.3)
    }

    func testSessionOpensWithoutCredentialsAndSerializesCommands() async throws {
        let pty = try PTY(); defer { pty.close() }
        let session = DeviceSession(identity: .init(id: "NO-CREDENTIALS", port: pty.path), replayDirectory: temporaryDirectory(), keychainEnabled: false)
        let opened = expectation(description: "opened")
        session.onOpen = { ready in XCTAssertFalse(ready); opened.fulfill() }
        session.start(); await fulfillment(of: [opened], timeout: 1)
        let first = Task { try await session.command("STATUS") }
        XCTAssertEqual(try pty.readLine(), "STATUS")
        let second = Task { try await session.command("HID_KEY_IDS") }
        XCTAssertNil(try pty.readLine(timeout: 0.05))
        try pty.writeLine("OK STATUS firmware=unified protocol=2 mode=hid sensor=ok fingerprints=1 hid_hosts=1")
        let firstLines = try await first.value
        XCTAssertTrue(firstLines.last?.hasPrefix("OK STATUS ") == true)
        XCTAssertEqual(try pty.readLine(), "HID_KEY_IDS")
        try pty.writeLine("OK HID_KEY_IDS ids=none capacity=8")
        let secondLines = try await second.value
        XCTAssertEqual(secondLines.last, "OK HID_KEY_IDS ids=none capacity=8")
        session.stop()
    }

    func testSessionEVAndEV2ResponsesAreFirmwareCompatible() async throws {
        for (index, kind) in ["EV", "EV2"].enumerated() {
            let pty = try PTY(); defer { pty.close() }
            let session = DeviceSession(identity: .init(id: "EVENT-\(index)", port: pty.path),
                password: Data("session-password".utf8), pairingKey: key, replayDirectory: temporaryDirectory())
            let opened = expectation(description: "opened \(kind)"); session.onOpen = { ready in XCTAssertTrue(ready); opened.fulfill() }
            session.start(); await fulfillment(of: [opened], timeout: 1)
            let nonce = String(format: "%032x", index + 20), id = try HIDProtocol.keyID(key)
            let line = kind == "EV"
                ? "EV \(nonce) 1 1 1 \(hmac("EV|\(nonce)|1|1|1"))"
                : "EV2 \(nonce) 1 1 1 \(id):\(hmac("EV2|\(id)|\(nonce)|1|1|1"))"
            try pty.writeLine(line)
            try assertPassword(try XCTUnwrap(pty.readLine()), expected: "session-password", key: key)
            session.stop()
        }
    }

    func testUnknownProtocolDoesNotServeCredentials() async throws {
        let pty = try PTY(); defer { pty.close() }
        let session = DeviceSession(identity: .init(id: "FUTURE", port: pty.path), password: Data("secret".utf8),
                                    pairingKey: key, replayDirectory: temporaryDirectory())
        let opened = expectation(description: "opened"); session.onOpen = { _ in opened.fulfill() }
        session.start(); await fulfillment(of: [opened], timeout: 1)
        let status = Task { try await session.command("STATUS") }
        XCTAssertEqual(try pty.readLine(), "STATUS")
        try pty.writeLine("OK STATUS firmware=future protocol=7 mode=hid sensor=ready fingerprints=1 hosts=1")
        _ = try await status.value
        let nonce = String(repeating: "19", count: 16)
        try pty.writeLine("EV \(nonce) 1 1 1 \(hmac("EV|\(nonce)|1|1|1"))")
        XCTAssertNil(try pty.readLine(timeout: 0.1)); session.stop()
    }

    func testTwoSessionsKeepResponsesIndependent() async throws {
        let a = try PTY(), b = try PTY(); defer { a.close(); b.close() }
        let keyA = key, keyB = Data(32..<64)
        let sa = DeviceSession(identity: .init(id: "A", port: a.path), password: Data("alpha".utf8),
                               pairingKey: keyA, replayDirectory: temporaryDirectory())
        let sb = DeviceSession(identity: .init(id: "B", port: b.path), password: Data("bravo".utf8),
                               pairingKey: keyB, replayDirectory: temporaryDirectory())
        let opened = expectation(description: "both opened"); opened.expectedFulfillmentCount = 2
        sa.onOpen = { _ in opened.fulfill() }; sb.onOpen = { _ in opened.fulfill() }
        sa.start(); sb.start(); await fulfillment(of: [opened], timeout: 1)
        let ta = Task { try await sa.command("STATUS") }, tb = Task { try await sb.command("STATUS") }
        XCTAssertEqual(try a.readLine(), "STATUS"); XCTAssertEqual(try b.readLine(), "STATUS")
        try b.writeLine("OK STATUS firmware=B protocol=1 mode=hid sensor=ok fingerprints=2")
        try a.writeLine("OK STATUS firmware=A protocol=1 mode=hid sensor=ok fingerprints=1")
        let linesA = try await ta.value, linesB = try await tb.value
        XCTAssertTrue(linesA.last?.contains("firmware=A") == true)
        XCTAssertTrue(linesB.last?.contains("firmware=B") == true)
        let nonceA = String(repeating: "a1", count: 16), nonceB = String(repeating: "b2", count: 16)
        try a.writeLine("EV \(nonceA) 1 1 1 \(hmac("EV|\(nonceA)|1|1|1", key: keyA))")
        try b.writeLine("EV \(nonceB) 1 1 1 \(hmac("EV|\(nonceB)|1|1|1", key: keyB))")
        try assertPassword(try XCTUnwrap(a.readLine()), expected: "alpha", key: keyA)
        try assertPassword(try XCTUnwrap(b.readLine()), expected: "bravo", key: keyB)
        sa.stop(); sb.stop()
    }

    func testPromptSuccessAndError() async throws {
        let pty = try PTY(); defer { pty.close() }
        let session = DeviceSession(identity: .init(id: "PROMPT", port: pty.path), replayDirectory: temporaryDirectory(), keychainEnabled: false)
        let opened = expectation(description: "opened"), prompt = expectation(description: "prompt")
        session.onOpen = { _ in opened.fulfill() }; session.onPrompt = { if $0 == "PROMPT TOUCH" { prompt.fulfill() } }
        session.start(); await fulfillment(of: [opened], timeout: 1)
        let success = Task { try await session.command("CONFIG_UNLOCK") }; _ = try pty.readLine()
        try pty.writeLine("PROMPT TOUCH"); try pty.writeLine("OK CONFIG_UNLOCK")
        await fulfillment(of: [prompt], timeout: 1)
        let successLines = try await success.value
        XCTAssertEqual(successLines.count, 2)
        let auth = Task { try await session.command("AUTH") }; XCTAssertEqual(try pty.readLine(), "AUTH")
        try pty.writeLine("EVENT TOUCH"); try pty.writeLine("OK AUTH")
        _ = try await auth.value
        let failure = Task { try await session.command("ENROLL 1") }; _ = try pty.readLine()
        try pty.writeLine("PROMPT LIFT"); try pty.writeLine("ERR ENROLL timeout")
        await assertFails(failure)
        session.stop()
    }

    func testTimeoutClosesSessionAndFailsQueuedRequestBeforeReconnect() async throws {
        let pty = try PTY(); defer { pty.close() }
        let firstSession = DeviceSession(identity: .init(id: "TIMEOUT", port: pty.path), replayDirectory: temporaryDirectory(), keychainEnabled: false)
        let opened = expectation(description: "opened"); firstSession.onOpen = { _ in opened.fulfill() }
        firstSession.start(); await fulfillment(of: [opened], timeout: 1)
        let first = Task { try await firstSession.command("STATUS", timeout: 0.05) }; _ = try pty.readLine()
        let queued = Task { try await firstSession.command("HID_KEY_IDS", timeout: 1) }
        await assertFails(first); await assertFails(queued)
        try? pty.writeLine("OK STATUS firmware=late protocol=1 mode=hid sensor=ok fingerprints=0")

        let secondSession = DeviceSession(identity: .init(id: "TIMEOUT", port: pty.path), replayDirectory: temporaryDirectory(), keychainEnabled: false)
        let reopened = expectation(description: "reopened"); secondSession.onOpen = { _ in reopened.fulfill() }
        secondSession.start(); await fulfillment(of: [reopened], timeout: 1)
        let retry = Task { try await secondSession.command("STATUS") }
        XCTAssertEqual(try pty.readLine(), "STATUS")
        try pty.writeLine("OK STATUS firmware=fresh protocol=1 mode=hid sensor=ok fingerprints=0")
        let retryLines = try await retry.value
        XCTAssertTrue(retryLines.last?.contains("firmware=fresh") == true); secondSession.stop()
    }

    func testDisconnectFailsActiveAndQueuedRequests() async throws {
        let pty = try PTY(), session = DeviceSession(identity: .init(id: "DISCONNECT", port: pty.path), replayDirectory: temporaryDirectory(), keychainEnabled: false)
        let opened = expectation(description: "opened"); session.onOpen = { _ in opened.fulfill() }
        session.start(); await fulfillment(of: [opened], timeout: 1)
        let active = Task { try await session.command("STATUS") }; _ = try pty.readLine()
        let queued = Task { try await session.command("HID_KEY_IDS") }
        pty.close(); await assertFails(active); await assertFails(queued)
    }

    func testDeviceManagerReconnectsAfterWakeOnNewPort() async throws {
        let oldPTY = try PTY(), newPTY = try PTY()
        defer { oldPTY.close(); newPTY.close() }
        let lease = LeaseObserver(directory: temporaryDirectory())
        let firstOpen = expectation(description: "first open"), secondOpen = expectation(description: "reopened")
        let state = await MainActor.run {
            DeviceManagerTestState(identity: .init(id: "WAKE", port: oldPTY.path), firstOpen: firstOpen, secondOpen: secondOpen)
        }
        let manager = await MainActor.run { () -> DeviceManager in
            let manager = DeviceManager(discover: { state.identities }, leaseObserver: lease, sessionUsesKeychain: false)
            manager.onChange = { _, active, _, _ in state.record(active) }
            manager.start(enabled: true)
            return manager
        }
        await fulfillment(of: [firstOpen], timeout: 1)

        let first = Task { try await manager.command(deviceID: "WAKE", "STATUS") }
        XCTAssertEqual(try oldPTY.readLine(), "STATUS")
        try oldPTY.writeLine("OK STATUS firmware=before protocol=2 mode=hid sensor=ok fingerprints=1")
        _ = try await first.value

        await MainActor.run {
            state.identities = [.init(id: "WAKE", port: newPTY.path)]
            manager.reconnectAfterWake()
        }
        await fulfillment(of: [secondOpen], timeout: 1)
        let second = Task { try await manager.command(deviceID: "WAKE", "STATUS") }
        XCTAssertEqual(try newPTY.readLine(), "STATUS")
        try newPTY.writeLine("OK STATUS firmware=after protocol=2 mode=hid sensor=ok fingerprints=1")
        _ = try await second.value
        await MainActor.run { manager.setEnabled(false) }
    }

    func testHeartbeatFailureReconnectsAndAcceptsProtocolSixPong() async throws {
        let pty = try PTY(); defer { pty.close() }
        let lease = LeaseObserver(directory: temporaryDirectory())
        let firstOpen = expectation(description: "heartbeat first open"), secondOpen = expectation(description: "heartbeat reopened")
        let thirdOpen = expectation(description: "heartbeat reopened without escalating backoff")
        let state = await MainActor.run {
            DeviceManagerTestState(identity: .init(id: "HEARTBEAT", port: pty.path), firstOpen: firstOpen,
                                   secondOpen: secondOpen, thirdOpen: thirdOpen)
        }
        let manager = await MainActor.run { () -> DeviceManager in
            let value = DeviceManager(discover: { state.identities },
                backoff: BackoffPolicy(initial: 0.01, maximum: 0.01, multiplier: 2, jitter: 0),
                random: { 0.5 }, leaseObserver: lease, heartbeatInterval: 0.05, heartbeatTimeout: 0.05,
                sessionUsesKeychain: false)
            value.onChange = { _, active, ready, errors in state.record(active, ready: ready, errors: errors) }
            value.start(enabled: true); return value
        }
        await fulfillment(of: [firstOpen], timeout: 1)
        await MainActor.run { manager.markReady("HEARTBEAT") }
        XCTAssertEqual(try pty.readLine(timeout: 1), "PING")
        await fulfillment(of: [secondOpen], timeout: 3)
        XCTAssertEqual(try pty.readLine(timeout: 1), "PING")
        await fulfillment(of: [thirdOpen], timeout: 3)
        XCTAssertEqual(try pty.readLine(timeout: 1), "PING")
        try pty.writeLine("PONG 6")
        await MainActor.run {
            XCTAssertFalse(state.reportedError)
            XCTAssertFalse(state.droppedReady)
        }
        await MainActor.run { manager.setEnabled(false) }
    }

    func testLiveCLILeaseSuspendsAcknowledgesAndResumesManager() async throws {
        let pty = try PTY(); defer { pty.close() }
        let lease = LeaseObserver(directory: temporaryDirectory())
        try FileManager.default.createDirectory(at: lease.directory, withIntermediateDirectories: true)
        let firstOpen = expectation(description: "lease first open"), secondOpen = expectation(description: "lease resumed")
        let state = await MainActor.run {
            DeviceManagerTestState(identity: .init(id: "LEASE", port: pty.path), firstOpen: firstOpen, secondOpen: secondOpen)
        }
        let manager = await MainActor.run { () -> DeviceManager in
            let value = DeviceManager(discover: { state.identities }, leaseObserver: lease, sessionUsesKeychain: false)
            value.onChange = { _, active, _, _ in state.record(active) }
            value.start(enabled: true); return value
        }
        await fulfillment(of: [firstOpen], timeout: 1)
        let record = LeaseRecord(schema: LeaseRecord.schema, pid: getpid(), nonce: String(repeating: "c", count: 32),
                                 acquiredAt: Date().timeIntervalSince1970)
        try JSONEncoder().encode(record).write(to: lease.leaseURL, options: .atomic)
        await MainActor.run { manager.scan() }
        let acknowledgement = try JSONSerialization.jsonObject(with: Data(contentsOf: lease.acknowledgementURL)) as? [String: Any]
        XCTAssertEqual(acknowledgement?["nonce"] as? String, record.nonce)
        do {
            _ = try await manager.command(deviceID: "LEASE", "STATUS")
            XCTFail("Lease should close the serial session")
        } catch {}
        try FileManager.default.removeItem(at: lease.leaseURL)
        await MainActor.run { manager.scan() }
        await fulfillment(of: [secondOpen], timeout: 1)
        await MainActor.run { manager.setEnabled(false) }
    }

    func testLineAndAccumulatedResponseLimits() async throws {
        try await assertProtocolLimit(id: "LINE") { pty in try pty.write(Data(repeating: 65, count: DeviceSession.maximumLineBytes + 1)) }
        try await assertProtocolLimit(id: "RESPONSE") { pty in
            let line = Data((String(repeating: "x", count: DeviceSession.maximumLineBytes) + "\n").utf8)
            for _ in 0...DeviceSession.maximumResponseBytes / line.count { try pty.write(line) }
        }
    }

    private func assertProtocolLimit(id: String, send: (PTY) throws -> Void) async throws {
        let pty = try PTY(); defer { pty.close() }
        let session = DeviceSession(identity: .init(id: id, port: pty.path), replayDirectory: temporaryDirectory(), keychainEnabled: false)
        let opened = expectation(description: "opened \(id)"); session.onOpen = { _ in opened.fulfill() }
        session.start(); await fulfillment(of: [opened], timeout: 1)
        let command = Task { try await session.command("STATUS", timeout: 1) }; _ = try pty.readLine()
        try send(pty); await assertFails(command)
    }

    private func assertPassword(_ response: String, expected: String, key: Data) throws {
        let parts = response.split(whereSeparator: \.isWhitespace).map(String.init), isV2 = parts[0] == "PW2"
        let nonceIndex = isV2 ? 2 : 1, ivIndex = nonceIndex + 1, cipherIndex = nonceIndex + 2, macIndex = nonceIndex + 3
        let material = parts[0...cipherIndex].joined(separator: "|")
        XCTAssertEqual(parts[macIndex], hmac(material, key: key))
        let sessionKey = hmacData("SESSION|\(parts[nonceIndex])", key: key)
        let clear = try HIDProtocol.aesCTR(key: sessionKey, iv: Data(strictHex: parts[ivIndex])!, input: Data(strictHex: parts[cipherIndex])!)
        XCTAssertEqual(String(decoding: clear, as: UTF8.self), expected)
    }
    private func assertFails<T>(_ task: Task<T, Error>) async {
        do { _ = try await task.value; XCTFail("Expected failure") } catch {}
    }
    private func hmac(_ message: String) -> String { hmacData(message).hex }
    private func hmac(_ message: String, key: Data) -> String { hmacData(message, key: key).hex }
    private func hmacData(_ message: String) -> Data {
        hmacData(message, key: key)
    }
    private func hmacData(_ message: String, key: Data) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: Data(message.utf8), using: SymmetricKey(data: key)))
    }
    private func temporaryDirectory() -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        temporaryDirectories.append(directory)
        return directory
    }
}

@MainActor
private final class DeviceManagerTestState {
    var identities: [DeviceIdentity]
    private(set) var reportedError = false, droppedReady = false
    private let id: String
    private var wasOpen = false, wasReady = false, openCount = 0
    private let firstOpen: XCTestExpectation, secondOpen: XCTestExpectation, thirdOpen: XCTestExpectation?

    init(identity: DeviceIdentity, firstOpen: XCTestExpectation, secondOpen: XCTestExpectation,
         thirdOpen: XCTestExpectation? = nil) {
        identities = [identity]; id = identity.id; self.firstOpen = firstOpen; self.secondOpen = secondOpen
        self.thirdOpen = thirdOpen
    }

    func record(_ active: Set<String>, ready: Set<String> = [], errors: [String: Error] = [:]) {
        if errors[id] != nil { reportedError = true }
        if ready.contains(id) { wasReady = true } else if wasReady { droppedReady = true }
        guard active.contains(id) else { wasOpen = false; return }
        guard !wasOpen else { return }
        wasOpen = true; openCount += 1
        if openCount == 1 { firstOpen.fulfill() }
        else if openCount == 2 { secondOpen.fulfill() }
        else if openCount == 3 { thirdOpen?.fulfill() }
    }
}

private final class PTY: @unchecked Sendable {
    private(set) var master: Int32 = -1
    let path: String
    init() throws {
        var slave: Int32 = -1, name = [CChar](repeating: 0, count: 128)
        guard openpty(&master, &slave, &name, nil, nil) == 0 else { throw DeviceError.disconnected }
        Darwin.close(slave); path = String(cString: name)
    }
    deinit { close() }
    func close() { if master >= 0 { Darwin.close(master); master = -1 } }
    func readLine(timeout: Double = 1) throws -> String? {
        var descriptor = pollfd(fd: master, events: Int16(POLLIN), revents: 0)
        guard poll(&descriptor, 1, Int32(timeout * 1000)) > 0 else { return nil }
        var bytes = [UInt8](repeating: 0, count: 8192); let count = Darwin.read(master, &bytes, bytes.count)
        guard count > 0 else { return nil }
        return String(decoding: bytes.prefix(count), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }
    func writeLine(_ line: String) throws { try write(Data((line + "\n").utf8)) }
    func write(_ data: Data) throws {
        var offset = 0
        while offset < data.count {
            let count = data.withUnsafeBytes { Darwin.write(master, $0.baseAddress!.advanced(by: offset), data.count - offset) }
            guard count > 0 else { throw DeviceError.disconnected }; offset += count
        }
    }
}
