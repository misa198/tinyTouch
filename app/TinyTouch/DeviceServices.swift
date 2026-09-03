import AppKit
import Darwin
import Foundation
import IOKit
import IOKit.serial
import LocalAuthentication
import Security

enum DeviceKind: String, Hashable { case runtime, rom, serialAdapter }

struct FlashOnboardingVisibility {
    private(set) var visible = false
    private var absentSince: Date?

    mutating func update(hasROM: Bool, now: Date = Date()) {
        if hasROM { visible = true; absentSince = nil }
        else if let absentSince, now.timeIntervalSince(absentSince) >= 2 { visible = false }
        else if absentSince == nil { absentSince = now }
    }
}

struct DeviceIdentity: Identifiable, Hashable {
    let id: String
    let port: String
    let kind: DeviceKind
    let locationID: Int?
    var name: String { kind == .rom ? "ESP32-S3 ROM \(id)" : kind == .serialAdapter ? "Serial adapter \(id)" : "tinyTouch \(id)" }
    init(id: String, port: String, kind: DeviceKind = .runtime, locationID: Int? = nil) {
        self.id = id; self.port = port; self.kind = kind; self.locationID = locationID
    }
    static func normalize(_ value: String) -> String {
        value.uppercased().filter { $0.isLetter || $0.isNumber || "_.-".contains($0) }
    }
}

struct DeviceStatus: Equatable {
    static let productID = "misa198.tinytouch.v1"
    let fields: [String: String]
    var firmwareVersion: String { fields["firmware_version"] ?? fields["firmware"] ?? "Unknown" }
    var protocolVersion: Int { Int(fields["protocol"] ?? "1") ?? 0 }
    var `protocol`: Int { protocolVersion }
    var dialect: DeviceDialect { DeviceDialect(protocolVersion: protocolVersion) }
    var isCompatible: Bool { dialect != .unsupported }
    var mode: String { fields["mode"] ?? "unknown" }
    var sensor: String { fields["sensor"] ?? "unknown" }
    var fingerprints: String { fields["fingerprints"] ?? "unknown" }
    var fingerprintCount: Int? { Int(fingerprints) }
    var sensorReady: Bool { ["ok", "ready"].contains(sensor) }
    var hidHosts: Int { Int(fields["hid_hosts"] ?? fields["hosts"] ?? "0") ?? 0 }
    var hidKeyConfigured: Bool { fields["hid_key"] == "configured" }
    var isFactoryDefault: Bool {
        protocolVersion == 6 && mode == "piv" && fields["piv"] == "unconfigured" &&
            fingerprintCount == 0 && hidHosts == 0
    }
    func isProvisioned(mode: SetupMode) -> Bool {
        protocolVersion == 6 && (fingerprintCount ?? 0) > 0 &&
            (mode == .hid ? hidHosts > 0 : fields["piv"] == "ready")
    }
    func isSetupComplete(mode: SetupMode) -> Bool {
        self.mode == mode.rawValue && isProvisioned(mode: mode)
    }

    init(line: String) throws {
        guard line.hasPrefix("OK STATUS ") else { throw DeviceError.response("Unrecognized STATUS response.") }
        fields = line.split(separator: " ").dropFirst(2).reduce(into: [:]) { result, item in
            let pair = item.split(separator: "=", maxSplits: 1).map(String.init)
            if pair.count == 2 { result[pair[0]] = pair[1] }
        }
        guard fields["mode"] != nil else { throw DeviceError.response("STATUS did not include a runtime mode.") }
    }
}

enum DeviceDialect: Equatable {
    case legacy, protocol6, unsupported

    init(protocolVersion: Int) {
        if (1...5).contains(protocolVersion) { self = .legacy }
        else if protocolVersion == 6 { self = .protocol6 }
        else { self = .unsupported }
    }

    var unlock: String { self == .protocol6 ? "AUTH" : "CONFIG_UNLOCK" }
    var hostList: String { self == .protocol6 ? "HOST LIST" : "HID_KEY_IDS" }
    func hostAdd(id: String, key: String) -> String {
        self == .protocol6 ? "HOST ADD \(id) \(key)" : "HID_KEY_ADD \(id) \(key)"
    }
    func hostRemove(id: String) -> String { self == .protocol6 ? "HOST REMOVE \(id)" : "HID_KEY_REMOVE \(id)" }
    func enroll(slot: Int) -> String { self == .protocol6 ? "FINGER ENROLL \(slot)" : "ENROLL \(slot)" }
    func delete(slot: Int) -> String { self == .protocol6 ? "FINGER DELETE \(slot)" : "DELETE \(slot)" }
    var clear: String { self == .protocol6 ? "FINGER CLEAR" : "DELETE_ALL" }
    var factoryReset: String? { self == .protocol6 ? "RESET FACTORY" : nil }
    func setMode(_ mode: SetupMode) -> String? { self == .protocol6 ? "SET MODE \(mode.rawValue.uppercased())" : nil }
    var pivCreate: String? { self == .protocol6 ? "PIV CREATE" : nil }
}

enum SetupMode: String, CaseIterable, Equatable { case hid, piv }

enum DeviceSetupPhase: Int, Equatable {
    case chooseMode, authenticate, registerMac, switchMode, createIdentity, enroll, verify, pair, complete
}

struct DeviceSetupState: Equatable {
    let deviceID: String
    let deviceName: String
    var mode: SetupMode?
    var phase: DeviceSetupPhase = .chooseMode
    var message = "Choose how you want to use tinyTouch."
    var error: String?
    var provisioningComplete = false
    var canSkipPairing = false
    var pairingStarted = false

    mutating func recordPairingFailure(_ message: String) {
        phase = .pair; error = message; provisioningComplete = true; canSkipPairing = true
    }
}

enum SetupValidation {
    static func password(_ password: String, confirmation: String, mode: KeyboardMode) throws {
        guard !password.isEmpty else { throw DeviceError.response("Password cannot be empty.") }
        guard password == confirmation else { throw DeviceError.response("Passwords do not match.") }
        guard password.utf8.count <= 160 else { throw DeviceError.response("Password must be 160 UTF-8 bytes or fewer.") }
        _ = try KeyboardMapper.translate(Data(password.utf8), mode: mode)
    }
}

enum SCAuthResult {
    static func identities(exitCode _: Int32, output: String, error: String) -> String? {
        if output.range(of: #"\b[0-9A-Fa-f]{40}\b"#, options: .regularExpression) != nil { return nil }
        return error.isEmpty ? "macOS has not discovered the tinyTouch PIV identity yet." : error
    }

    static func pairingLaunch(exitCode: Int32, error: String) -> String? {
        exitCode == -1 ? (error.isEmpty ? "macOS PIV pairing could not start." : error) : nil
    }
}

struct HIDHostList: Equatable {
    let ids: [String]
    let capacity: Int
    init(line: String) throws {
        let prefix = line.hasPrefix("OK HOST LIST ") ? "OK HOST LIST " : "OK HID_KEY_IDS "
        guard line.hasPrefix(prefix) else { throw DeviceError.response("Unrecognized computer list.") }
        let fields = line.split(separator: " ").dropFirst(2).reduce(into: [String: String]()) { result, item in
            let pair = item.split(separator: "=", maxSplits: 1).map(String.init)
            if pair.count == 2 { result[pair[0]] = pair[1] }
        }
        let raw = fields["ids"] ?? "none"
        ids = raw == "none" || raw.isEmpty ? [] : raw.split(separator: ",").map { $0.lowercased() }
        capacity = Int(fields["capacity"] ?? "0") ?? 0
        guard ids.allSatisfy({ Data(strictHex: $0, count: 8) != nil }) else {
            throw DeviceError.response("The device returned an invalid computer ID.")
        }
    }
}

enum DeviceError: Error, LocalizedError {
    case disconnected, busy(String), timeout, protocolViolation(String), response(String), missingCredentials
    case unsupportedProtocol(Int), foreignFirmware, keychain(OSStatus)
    var errorDescription: String? {
        switch self {
        case .disconnected: "tinyTouch disconnected."
        case .busy(let detail): "The serial port is busy. Close the legacy helper, serial monitors, and browser flashing tabs. \(detail)"
        case .timeout: "tinyTouch did not answer before the command timed out."
        case .protocolViolation(let detail): "tinyTouch closed an unsafe serial response: \(detail)"
        case .response(let message): message
        case .missingCredentials: "This Mac has no HID credentials for this device. Complete HID Setup first."
        case .unsupportedProtocol(let version): "Protocol \(version) is newer than this TinyTouch app supports. Update the app before using HID credentials."
        case .foreignFirmware: "This board is running firmware from a different tinyTouch product. Enter ESP32-S3 ROM mode to factory-flash misa198 firmware."
        case .keychain(let status): "Keychain could not access the tinyTouch credential (OSStatus \(status)). Unlock Keychain access, then choose Retry."
        }
    }
    var blocksReconnect: Bool {
        if case .busy = self { return true }
        return false
    }
}

enum KeychainStore {
    static let passwordService = "misa198.TinyTouch.password", pairingService = "misa198.TinyTouch.pairing"
    static func result(status: OSStatus, data: CFTypeRef?) throws -> Data? {
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw DeviceError.keychain(status) }
        guard let data = data as? Data else { throw DeviceError.keychain(errSecDecode) }
        return data
    }
    static func get(service: String, account: String, background: Bool = false) throws -> Data? {
        var query: [CFString: Any] = [kSecClass: kSecClassGenericPassword, kSecAttrService: service,
            kSecAttrAccount: account, kSecReturnData: true, kSecMatchLimit: kSecMatchLimitOne]
        let context = LAContext()
        if background { context.interactionNotAllowed = true; query[kSecUseAuthenticationContext] = context }
        var value: CFTypeRef?
        return try result(status: SecItemCopyMatching(query as CFDictionary, &value), data: value)
    }
    static func pairingKey(account: String, background: Bool = false) throws -> Data? {
        guard let data = try get(service: pairingService, account: account, background: background),
              let text = String(data: data, encoding: .utf8)
        else { return nil }
        return Data(strictHex: text.trimmingCharacters(in: .whitespacesAndNewlines), count: 32)
    }
    static func set(_ data: Data, service: String, account: String) throws {
        let base: [CFString: Any] = [kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: account]
        var status = SecItemUpdate(base as CFDictionary, [kSecValueData: data] as CFDictionary)
        if status == errSecItemNotFound {
            var item = base; item[kSecValueData] = data; status = SecItemAdd(item as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw DeviceError.keychain(status) }
    }
    static func delete(service: String, account: String) throws {
        let query: [CFString: Any] = [kSecClass: kSecClassGenericPassword,
            kSecAttrService: service, kSecAttrAccount: account]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw DeviceError.keychain(status) }
    }
}

struct BackoffPolicy {
    var initial: TimeInterval = 0.25, maximum: TimeInterval = 30, multiplier = 2.0, jitter = 0.2
    func delay(failures: Int, random: Double = Double.random(in: 0...1)) -> TimeInterval {
        let base = min(maximum, initial * pow(multiplier, Double(max(0, failures - 1))))
        let spread = base * jitter
        return max(0, base - spread + 2 * spread * random)
    }
}

struct SerialFrameDecoder {
    let maximum: Int
    private(set) var buffer = Data()
    private(set) var discarding = false

    mutating func feed(_ chunk: Data) -> [Data] {
        var frames: [Data] = []
        for byte in chunk {
            if discarding {
                if byte == 0x0A { discarding = false }
            } else if byte == 0x0A {
                frames.append(buffer); buffer.removeAll(keepingCapacity: true)
            } else {
                buffer.append(byte)
                if buffer.count > maximum { buffer.removeAll(keepingCapacity: true); discarding = true }
            }
        }
        return frames
    }

    mutating func discardPartial() -> Bool {
        let hadPartial = !buffer.isEmpty || discarding
        buffer.removeAll(keepingCapacity: false); discarding = false
        return hadPartial
    }
}

struct LeaseRecord: Codable, Equatable {
    static let schema = 1, maximumAge: TimeInterval = 6 * 60 * 60
    let schema: Int, pid: Int32, nonce: String, acquiredAt: TimeInterval
    enum CodingKeys: String, CodingKey { case schema, pid, nonce, acquiredAt = "acquired_at" }

    var isValid: Bool {
        schema == Self.schema && pid > 1 && nonce == nonce.lowercased() && Data(strictHex: nonce, count: 16) != nil &&
            Date().timeIntervalSince1970 - acquiredAt >= -60 &&
            Date().timeIntervalSince1970 - acquiredAt <= Self.maximumAge &&
            (Darwin.kill(pid, 0) == 0 || errno == EPERM)
    }
}

struct LeaseObserver {
    var directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("misa198.TinyTouch", isDirectory: true)
    var leaseURL: URL { directory.appendingPathComponent("helper-suspend") }
    var acknowledgementURL: URL { directory.appendingPathComponent("helper-suspend-ack") }

    func active() -> LeaseRecord? {
        guard let data = try? Data(contentsOf: leaseURL),
              let record = try? JSONDecoder().decode(LeaseRecord.self, from: data), record.isValid else {
            try? FileManager.default.removeItem(at: leaseURL)
            try? FileManager.default.removeItem(at: acknowledgementURL)
            return nil
        }
        return record
    }

    func acknowledge(_ record: LeaseRecord) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let value: [String: Any] = ["schema": LeaseRecord.schema, "pid": getpid(), "nonce": record.nonce]
        try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
            .write(to: acknowledgementURL, options: .atomic)
    }
}

enum CredentialMigrator {
    static let legacyAccounts = ["tinyTouch", "B8F862FB478C"]

    static func provenSource(destination: String, hostIDs: [String], key: (String) throws -> Data?) rethrows -> String? {
        let registered = Set(hostIDs.map { $0.lowercased() })
        for account in legacyAccounts where account != destination {
            if let candidate = try key(account),
               registered.contains((try? HIDProtocol.keyID(candidate)) ?? "") { return account }
        }
        return nil
    }

    static func migrateIfProven(deviceID: String, hostIDs: [String], directory: URL? = nil) throws -> Bool {
        guard try KeychainStore.pairingKey(account: deviceID, background: true) == nil,
              let source = try provenSource(destination: deviceID, hostIDs: hostIDs,
                  key: { try KeychainStore.pairingKey(account: $0, background: true) }),
              let pairing = try KeychainStore.get(service: KeychainStore.pairingService, account: source, background: true)
        else { return false }
        let password = try KeychainStore.get(service: KeychainStore.passwordService, account: source, background: true)
            ?? (source == "tinyTouch" ? nil : try KeychainStore.get(service: KeychainStore.passwordService,
                account: "tinyTouch", background: true))
        try KeychainStore.set(pairing, service: KeychainStore.pairingService, account: deviceID)
        if let password, try KeychainStore.get(service: KeychainStore.passwordService, account: deviceID, background: true) == nil {
            try KeychainStore.set(password, service: KeychainStore.passwordService, account: deviceID)
        }
        let root = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("misa198.TinyTouch", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for kind in ["state", "settings"] {
            let destination = root.appendingPathComponent("\(kind)-\(DeviceIdentity.normalize(deviceID)).json")
            guard !FileManager.default.fileExists(atPath: destination.path) else { continue }
            for candidate in ["\(kind)-\(DeviceIdentity.normalize(source)).json", "\(kind)-legacy.json"] {
                let sourceURL = root.appendingPathComponent(candidate)
                if let data = try? Data(contentsOf: sourceURL) { try data.write(to: destination, options: .atomic); break }
            }
        }
        return true
    }
}

enum DiagnosticsStore {
    static let maximumBytes = 2 * 1024 * 1024
    private static let lock = NSLock()
    static var directory = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Logs/misa198.TinyTouch", isDirectory: true)
    static var logURL: URL { directory.appendingPathComponent("runtime.jsonl") }

    static func record(_ event: String, level: String = "info", deviceID: String? = nil,
                       fields: [String: String] = [:]) {
        var value = fields.filter { ["reason", "port", "protocol", "fingerprint_slot", "retry_seconds", "owner_pid"].contains($0.key) }
        value["time"] = ISO8601DateFormatter().string(from: Date()); value["level"] = level; value["event"] = event
        if let deviceID { value["device_id"] = DeviceIdentity.normalize(deviceID) }
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]),
              var line = String(data: data, encoding: .utf8).map({ Data(($0 + "\n").utf8) }) else { return }
        lock.lock(); defer { lock.unlock() }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let size = (try? logURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            if size + line.count > maximumBytes {
                let first = directory.appendingPathComponent("runtime.jsonl.1")
                let second = directory.appendingPathComponent("runtime.jsonl.2")
                try? FileManager.default.removeItem(at: second)
                if FileManager.default.fileExists(atPath: first.path) { try FileManager.default.moveItem(at: first, to: second) }
                if FileManager.default.fileExists(atPath: logURL.path) { try FileManager.default.moveItem(at: logURL, to: first) }
            }
            if !FileManager.default.fileExists(atPath: logURL.path) {
                _ = FileManager.default.createFile(atPath: logURL.path, contents: nil,
                                                   attributes: [.posixPermissions: 0o600])
            }
            let handle = try FileHandle(forWritingTo: logURL); defer { try? handle.close() }
            try handle.seekToEnd(); try handle.write(contentsOf: line)
            line.resetBytes(in: line.startIndex..<line.endIndex)
        } catch {}
    }

    static func export(to url: URL, devices: [DeviceIdentity], states: [String: String]) throws {
        let events = ((try? String(contentsOf: logURL, encoding: .utf8)) ?? "")
            .split(separator: "\n").suffix(200).map(String.init)
        let payload: [String: Any] = [
            "generated_at": ISO8601DateFormatter().string(from: Date()),
            "app": states.filter { ["background_enabled", "launch_at_login", "device_count", "legacy_helper_detected"].contains($0.key) },
            "devices": devices.map { ["id": DeviceIdentity.normalize($0.id), "port": $0.port] },
            "events": events.compactMap { line in
                (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any]
            },
        ]
        try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
            .write(to: url, options: .atomic)
    }
}

enum SerialDiscovery {
    static let runtimeManufacturer = "misa198", runtimeProduct = "misa198 tinyTouch", runtimeSerialPrefix = "MISA198-TT-"
    static func runtimeIdentity(vendorID: Int?, productID: Int?, serial: String?, port: String,
                                manufacturer: String? = nil, product: String? = nil) -> DeviceIdentity? {
        guard vendorID == 0x303A, productID == 0x4001, manufacturer == runtimeManufacturer,
              product == runtimeProduct, let serial else { return nil }
        let id = DeviceIdentity.normalize(serial)
        guard id.hasPrefix(runtimeSerialPrefix), id.count == runtimeSerialPrefix.count + 12,
              id.dropFirst(runtimeSerialPrefix.count).allSatisfy({ $0.isHexDigit }) else { return nil }
        return DeviceIdentity(id: id, port: port)
    }
    static func identity(vendorID: Int?, productID: Int?, serial: String?, locationID: Int?,
                         port: String, advanced: Bool, manufacturer: String? = nil, product: String? = nil) -> DeviceIdentity? {
        if let runtime = runtimeIdentity(vendorID: vendorID, productID: productID, serial: serial, port: port,
                                         manufacturer: manufacturer, product: product) {
            return DeviceIdentity(id: runtime.id, port: port, locationID: locationID)
        }
        let location = locationID.map { String(format: "%08X", $0) } ?? DeviceIdentity.normalize(serial ?? port)
        if vendorID == 0x303A, productID.map({ [0x1001, 0x0002].contains($0) }) == true {
            return DeviceIdentity(id: "ROM-\(location)", port: port, kind: .rom, locationID: locationID)
        }
        let adapter = vendorID == 0x10C4 && productID == 0xEA60 ||
            vendorID == 0x1A86 && productID.map({ [0x7523, 0x55D3, 0x55D4].contains($0) }) == true
        return advanced && adapter ? DeviceIdentity(id: "USB-\(location)", port: port, kind: .serialAdapter, locationID: locationID) : nil
    }
    static func devices(advanced: Bool = false) -> [DeviceIdentity] {
        let matching = IOServiceMatching(kIOSerialBSDServiceValue); var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(iterator) }
        var found: [DeviceIdentity] = []
        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            guard let port = property(kIOCalloutDeviceKey, service: service), port.hasPrefix("/dev/cu."),
                  let identity = identity(vendorID: ancestorNumber("idVendor", service: service),
                      productID: ancestorNumber("idProduct", service: service),
                      serial: ancestorProperty("USB Serial Number", service: service),
                      locationID: ancestorNumber("locationID", service: service), port: port, advanced: advanced,
                      manufacturer: ancestorProperty("USB Vendor Name", service: service),
                      product: ancestorProperty("USB Product Name", service: service)) else { continue }
            found.append(identity)
        }
        return found.sorted { $0.port < $1.port }
    }
    private static func property(_ key: String, service: io_registry_entry_t) -> String? {
        IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? String
    }
    private static func ancestorProperty(_ key: String, service: io_registry_entry_t) -> String? {
        ancestorValue(key, service: service) as? String
    }
    private static func ancestorNumber(_ key: String, service: io_registry_entry_t) -> Int? {
        (ancestorValue(key, service: service) as? NSNumber)?.intValue
    }
    private static func ancestorValue(_ key: String, service: io_registry_entry_t) -> Any? {
        var current = service, owned = false
        defer { if owned { IOObjectRelease(current) } }
        for _ in 0..<12 {
            if let value = IORegistryEntryCreateCFProperty(current, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() { return value }
            var parent: io_registry_entry_t = 0
            guard IORegistryEntryGetParentEntry(current, kIOServicePlane, &parent) == KERN_SUCCESS else { break }
            if owned { IOObjectRelease(current) }; current = parent; owned = true
        }
        return nil
    }
}

struct PortOwner: Identifiable, Equatable {
    let pid: Int32
    var name: String
    var command: String
    var ports: [String]
    var id: Int32 { pid }
    var detail: String { "PID \(pid) — \(name): \(command) [\(ports.joined(separator: ", "))]" }
    var isLegacyHelper: Bool {
        let value = (name + " " + command).lowercased()
        return value.contains("com.tinytouch.helper") || value.contains("tinytouch_helper.py") || value.contains("tinytouch-service _helper")
    }
}

enum LegacyProcessInspector {
    static func parseLsof(_ output: String) -> [PortOwner] {
        var owners: [Int32: PortOwner] = [:], pid: Int32?, name = "unknown"
        for line in output.split(whereSeparator: \.isNewline).map(String.init) {
            guard let prefix = line.first else { continue }
            let value = String(line.dropFirst())
            switch prefix {
            case "p": pid = Int32(value); name = owners[pid ?? -1]?.name ?? "unknown"
            case "c": name = value
            case "n":
                guard let pid, pid != getpid() else { continue }
                var owner = owners[pid] ?? PortOwner(pid: pid, name: name, command: name, ports: [])
                if !owner.ports.contains(value) { owner.ports.append(value) }; owners[pid] = owner
            default: break
            }
        }
        return owners.values.sorted { $0.pid < $1.pid }
    }

    static func parsePS(_ output: String) -> [Int32: (String, String)] {
        output.split(whereSeparator: \.isNewline).reduce(into: [:]) { result, raw in
            let fields = raw.split(maxSplits: 2, whereSeparator: \.isWhitespace)
            if fields.count == 3, let pid = Int32(fields[0]) { result[pid] = (String(fields[1]), String(fields[2])) }
        }
    }

    static func owners(ports: [String]) -> [PortOwner] {
        guard !ports.isEmpty else { return [] }
        var owners = parseLsof(run("/usr/sbin/lsof", ["-Fpcn", "--"] + ports))
        guard !owners.isEmpty else { return [] }
        let ps = parsePS(run("/bin/ps", ["-p", owners.map { String($0.pid) }.joined(separator: ","), "-o", "pid=", "-o", "comm=", "-o", "command="]))
        for index in owners.indices where ps[owners[index].pid] != nil {
            owners[index].name = ps[owners[index].pid]!.0; owners[index].command = ps[owners[index].pid]!.1
        }
        return owners
    }

    static func waitForRelease(timeout: TimeInterval, inspect: () -> [PortOwner]) -> [PortOwner] {
        let deadline = Date().addingTimeInterval(timeout)
        var remaining = inspect()
        while !remaining.isEmpty && Date() < deadline { usleep(100_000); remaining = inspect() }
        return remaining
    }

    @discardableResult static func run(_ executable: String, _ arguments: [String]) -> String {
        let process = Process(), output = Pipe()
        process.executableURL = URL(fileURLWithPath: executable); process.arguments = arguments
        process.standardOutput = output; process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return "" }
        process.waitUntilExit()
        return String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    }
}

final class DeviceSession: @unchecked Sendable {
    static let maximumLineBytes = 2 * 1024, maximumResponseBytes = 64 * 1024
    let identity: DeviceIdentity
    var onPrompt: (@Sendable (String) -> Void)?
    var onError: (@Sendable (Error) -> Void)?
    var onOpen: (@Sendable (Bool) -> Void)?

    private final class Pending {
        let id = UUID(), command: String
        var lines: [String] = [], responseBytes = 0
        let continuation: CheckedContinuation<[String], Error>
        init(_ command: String, _ continuation: CheckedContinuation<[String], Error>) {
            self.command = command; self.continuation = continuation
        }
    }
    private let queue: DispatchQueue
    private var descriptor: Int32 = -1
    private var source: DispatchSourceRead?, decoder = SerialFrameDecoder(maximum: maximumLineBytes)
    private var requests: [Pending] = [], active: Pending?
    private var replayState: ReplayState
    private let stateStore: ReplayStateStore, settingsStore: KeyboardSettingsStore
    private let suppliedPasswords: [Int: Data]?, suppliedKey: Data?
    private let heartbeatInterval: TimeInterval, heartbeatTimeout: TimeInterval
    private let keychainEnabled: Bool
    private var lastReceived = Date(), heartbeatSentAt: Date?, protocolVersion: Int?, productVerified = false

    init(identity: DeviceIdentity, password: Data? = nil, passwords: [Int: Data]? = nil,
         pairingKey: Data? = nil, replayDirectory: URL? = nil,
         heartbeatInterval: TimeInterval = 5, heartbeatTimeout: TimeInterval = 2,
         keychainEnabled: Bool = true) {
        self.identity = identity; suppliedPasswords = passwords ?? password.map { [0: $0] }; suppliedKey = pairingKey
        self.heartbeatInterval = heartbeatInterval; self.heartbeatTimeout = heartbeatTimeout
        self.keychainEnabled = keychainEnabled
        queue = DispatchQueue(label: "misa198.TinyTouch.serial.\(identity.id)")
        stateStore = replayDirectory.map { ReplayStateStore(directory: $0) } ?? ReplayStateStore()
        settingsStore = replayDirectory.map { KeyboardSettingsStore(directory: $0) } ?? KeyboardSettingsStore()
        replayState = stateStore.load(deviceID: identity.id)
    }

    func start() { queue.async { self.openPort() } }
    func stop() { queue.async { self.close(DeviceError.disconnected, report: false) } }
    func stopSynchronously() { queue.sync { self.close(DeviceError.disconnected, report: false) } }
    func command(_ value: String, timeout: TimeInterval = 45) async throws -> [String] {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                guard self.descriptor >= 0 else { continuation.resume(throwing: DeviceError.disconnected); return }
                let request = Pending(value, continuation); self.requests.append(request); self.sendNext()
                self.queue.asyncAfter(deadline: .now() + timeout) {
                    guard self.active?.id == request.id else { return }
                    self.close(DeviceError.timeout)
                }
            }
        }
    }

    private func openPort() {
        guard descriptor < 0 else { return }
        descriptor = Darwin.open(identity.port, O_RDWR | O_NOCTTY | O_NONBLOCK)
        guard descriptor >= 0 else {
            let error: DeviceError = errno == EBUSY ? .busy(identity.port) : .disconnected
            close(error); return
        }
        _ = fcntl(descriptor, F_SETFL, 0)
        var settings = termios()
        guard tcgetattr(descriptor, &settings) == 0 else { close(DeviceError.disconnected); return }
        cfmakeraw(&settings); cfsetspeed(&settings, speed_t(B115200))
        settings.c_cflag |= tcflag_t(CLOCAL | CREAD | CS8); settings.c_cflag &= ~tcflag_t(PARENB | CSTOPB | CRTSCTS)
        settings.c_cc.16 = 0; settings.c_cc.17 = 2
        guard tcsetattr(descriptor, TCSANOW, &settings) == 0 else { close(DeviceError.disconnected); return }
        var dtr = Int32(TIOCM_DTR), rts = Int32(TIOCM_RTS)
        _ = ioctl(descriptor, TIOCMBIS, &dtr); _ = ioctl(descriptor, TIOCMBIC, &rts)
        let readSource = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: queue)
        readSource.setEventHandler { [weak self] in self?.readAvailable() }
        source = readSource; readSource.resume()
        do {
            let password = try passwords()[0], key = try pairingKey()
            lastReceived = Date(); onOpen?(password != nil && key != nil); sendNext(); heartbeatTick()
        }
        catch { close(error) }
    }

    private func readAvailable() {
        var bytes = [UInt8](repeating: 0, count: 1024)
        let count = Darwin.read(descriptor, &bytes, bytes.count)
        guard count > 0 else {
            if count == 0 || (errno != EAGAIN && errno != EINTR) { close(DeviceError.disconnected) }
            return
        }
        lastReceived = Date(); heartbeatSentAt = nil
        let wasDiscarding = decoder.discarding
        for raw in decoder.feed(Data(bytes.prefix(count))) {
            guard let line = String(data: raw, encoding: .utf8) else { close(DeviceError.protocolViolation("invalid UTF-8")); return }
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { receive(Self.resynchronizeEvent(trimmed), bytes: raw.count + 1) }
            if descriptor < 0 { return }
        }
        if !wasDiscarding && decoder.discarding {
            DiagnosticsStore.record("protocol.frame_rejected", level: "warning", deviceID: identity.id,
                                    fields: ["reason": "oversized"])
        }
    }

    private func receive(_ line: String, bytes: Int) {
        if line.hasPrefix("EV ") || line.hasPrefix("EV2 ") { handleEvent(line); return }
        if line.hasPrefix("OK STATUS "), let status = try? DeviceStatus(line: line) {
            protocolVersion = status.protocolVersion
            productVerified = status.fields["product_id"] == DeviceStatus.productID
        }
        if line == "PONG" || line == "PONG 6" {
            heartbeatSentAt = nil
            if active?.command != "PING" { return }
        }
        guard let active else { return }
        active.responseBytes += bytes
        guard active.responseBytes <= Self.maximumResponseBytes else {
            close(DeviceError.protocolViolation("response exceeds 64 KiB")); return
        }
        active.lines.append(line)
        if line.hasPrefix("PROMPT ") || line == "EVENT TOUCH" { onPrompt?(line); return }
        if line.hasPrefix("ERR ") { finish(.failure(DeviceError.response(Self.humanError(line)))); return }
        if line.hasPrefix("OK ") || line == "OK" || line == "PONG" || line == "PONG 6" { finish(.success(active.lines)) }
    }

    private func handleEvent(_ line: String) {
        let mode = settingsStore.load(deviceID: identity.id).keyboardLayout
        guard mode == .auto else { handleEvent(line, keyboardMode: mode); return }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            do {
                let map = try KeyboardMapper.currentOutputMap()
                self.queue.async { self.handleEvent(line, keyboardMode: mode, keyboardMap: map) }
            } catch {
                self.queue.async {
                    DiagnosticsStore.record("protocol.event_rejected", level: "warning", deviceID: self.identity.id,
                                            fields: ["reason": "keyboard_layout"])
                }
            }
        }
    }

    private func handleEvent(_ line: String, keyboardMode: KeyboardMode,
                             keyboardMap: [Character: Character]? = nil) {
        do {
            guard productVerified else {
                DiagnosticsStore.record("protocol.event_rejected", level: "warning", deviceID: identity.id,
                                        fields: ["reason": "unverified_product"])
                return
            }
            guard protocolVersion.map({ (1...6).contains($0) }) ?? true else {
                DiagnosticsStore.record("protocol.event_rejected", level: "warning", deviceID: identity.id,
                                        fields: ["reason": "unsupported_protocol", "protocol": String(protocolVersion!)])
                return
            }
            let storedPasswords = try passwords(), storedKey = try pairingKey()
            guard !storedPasswords.isEmpty, let key = storedKey else { return }
            if let reply = try HIDProtocol.response(to: line, passwords: storedPasswords, pairingKey: key,
                                                     state: replayState, keyboardMode: keyboardMode, keyboardMap: keyboardMap) {
                try HIDProtocol.deliver(reply, state: &replayState, store: stateStore,
                                        deviceID: identity.id, write: write)
                DiagnosticsStore.record("protocol.password_delivered", deviceID: identity.id,
                                        fields: ["fingerprint_slot": String(reply.slot)])
            }
        } catch HIDProtocolError.wrongKeyID {} catch let error as DeviceError {
            close(error)
        } catch {
            DiagnosticsStore.record("protocol.event_rejected", level: "warning", deviceID: identity.id,
                                    fields: ["reason": "invalid_event"])
        }
    }
    private func passwords() throws -> [Int: Data] {
        if let suppliedPasswords { return suppliedPasswords }
        if !keychainEnabled { return [:] }
        var result: [Int: Data] = [:]
        if let password = try KeychainStore.get(service: KeychainStore.passwordService, account: identity.id, background: true) {
            result[0] = password
        }
        for slot in 1...5 {
            let account = "\(identity.id):fingerprint:\(slot)"
            if let password = try KeychainStore.get(service: KeychainStore.passwordService, account: account, background: true) {
                result[slot] = password
            }
        }
        return result
    }
    private func pairingKey() throws -> Data? {
        if let suppliedKey { return suppliedKey }
        return keychainEnabled ? try KeychainStore.pairingKey(account: identity.id, background: true) : nil
    }
    private func sendNext() {
        guard descriptor >= 0, active == nil, !requests.isEmpty else { return }
        active = requests.removeFirst()
        do { try write(active!.command + "\n") } catch { close(error) }
    }
    private func write(_ text: String) throws {
        let data = Data(text.utf8); var offset = 0
        while offset < data.count {
            let written = data.withUnsafeBytes { Darwin.write(descriptor, $0.baseAddress!.advanced(by: offset), data.count - offset) }
            if written > 0 { offset += written } else if errno != EINTR { throw DeviceError.disconnected }
        }
        guard tcdrain(descriptor) == 0 else { throw DeviceError.disconnected }
    }
    private func finish(_ result: Result<[String], Error>) {
        guard let request = active else { return }
        active = nil; request.continuation.resume(with: result); sendNext()
    }
    private func close(_ error: Error, report: Bool = true) {
        source?.cancel(); source = nil
        if descriptor >= 0 { Darwin.close(descriptor); descriptor = -1 }
        _ = decoder.discardPartial(); heartbeatSentAt = nil
        if let active { self.active = nil; active.continuation.resume(throwing: error) }
        requests.forEach { $0.continuation.resume(throwing: error) }; requests.removeAll()
        if report { onError?(error) }
    }
    private func heartbeatTick() {
        guard descriptor >= 0 else { return }
        let now = Date()
        if let sent = heartbeatSentAt, now.timeIntervalSince(sent) >= heartbeatTimeout {
            close(DeviceError.timeout); return
        }
        if decoder.buffer.count > 0, now.timeIntervalSince(lastReceived) >= 1 {
            if decoder.discardPartial() {
                DiagnosticsStore.record("protocol.partial_frame_expired", level: "warning", deviceID: identity.id)
            }
        }
        if heartbeatSentAt == nil, active == nil, requests.isEmpty,
           now.timeIntervalSince(lastReceived) >= heartbeatInterval {
            do { try write("PING\n"); heartbeatSentAt = now } catch { close(error); return }
        }
        queue.asyncAfter(deadline: .now() + min(0.25, heartbeatInterval)) { [weak self] in self?.heartbeatTick() }
    }
    static func resynchronizeEvent(_ line: String) -> String {
        let markers = [line.range(of: "EV ", options: .backwards), line.range(of: "EV2 ", options: .backwards)]
            .compactMap { $0?.lowerBound }.sorted()
        guard let marker = markers.last, marker > line.startIndex else { return line }
        return String(line[marker...])
    }
    private static func humanError(_ line: String) -> String {
        switch line {
        case "ERR AUTH": "The fingerprint was not recognized or authorization timed out. Try again."
        case "ERR CONFIG_UNLOCK sensor": "The fingerprint sensor cannot authorize configuration."
        case "ERR CONFIG_UNLOCK fingerprint": "The fingerprint was not recognized before authorization expired."
        case "ERR CONFIG_LOCKED run=CONFIG_UNLOCK": "Configuration is locked; authenticate with a fingerprint and try again."
        case "ERR HID_KEY_ADD": "This device could not add the Mac; its eight-computer list may be full."
        case "ERR HID_KEY_REMOVE": "That computer ID was not found or could not be removed."
        default: line.hasPrefix("ERR ENROLL") ? "Fingerprint enrollment did not complete." : "Device error: \(line)"
        }
    }
}

@MainActor
final class DeviceManager {
    var onChange: (@MainActor ([DeviceIdentity], Set<String>, Set<String>, [String: Error]) -> Void)?
    var onPrompt: (@MainActor (String, String) -> Void)?
    private var sessions: [String: DeviceSession] = [:], identities: [DeviceIdentity] = []
    private var errors: [String: Error] = [:], opened: Set<String> = [], ready: Set<String> = [], blocked: Set<String> = [], exclusive: Set<String> = []
    var retryDeadlines: [String: Date] = [:]
    private let discover: @MainActor () -> [DeviceIdentity]
    private let defaultDiscovery: Bool
    private let backoff: BackoffPolicy, random: () -> Double, leaseObserver: LeaseObserver
    private let heartbeatInterval: TimeInterval, heartbeatTimeout: TimeInterval
    private let sessionUsesKeychain: Bool
    private var failures: [String: Int] = [:], activeLeaseNonce: String?
    private var enabled = true, advancedDiscovery = false, timer: Timer?, wakeObserver: NSObjectProtocol?

    init(discover: (@MainActor () -> [DeviceIdentity])? = nil,
         backoff: BackoffPolicy = BackoffPolicy(), random: @escaping () -> Double = { Double.random(in: 0...1) },
         leaseObserver: LeaseObserver = LeaseObserver(), heartbeatInterval: TimeInterval = 5,
         heartbeatTimeout: TimeInterval = 2, sessionUsesKeychain: Bool = true) {
        self.discover = discover ?? { SerialDiscovery.devices() }; defaultDiscovery = discover == nil
        self.backoff = backoff; self.random = random; self.leaseObserver = leaseObserver
        self.heartbeatInterval = heartbeatInterval; self.heartbeatTimeout = heartbeatTimeout
        self.sessionUsesKeychain = sessionUsesKeychain
    }

    deinit {
        if let wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver) }
    }

    func start(enabled: Bool) {
        self.enabled = enabled; observeWake(); scan()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in Task { @MainActor in self?.scan() } }
    }
    func setEnabled(_ enabled: Bool) {
        self.enabled = enabled
        if !enabled { sessions.values.forEach { $0.stop() }; sessions.removeAll(); opened.removeAll(); ready.removeAll() }
        scan()
    }
    func setAdvancedDiscovery(_ enabled: Bool) { advancedDiscovery = enabled; scan() }
    func retry(_ deviceID: String) {
        blocked.remove(deviceID); failures[deviceID] = nil; retryDeadlines[deviceID] = nil; errors[deviceID] = nil; scan()
    }
    func command(deviceID: String, _ command: String, timeout: TimeInterval = 45) async throws -> [String] {
        guard enabled, let session = sessions[deviceID] else { throw DeviceError.disconnected }
        return try await session.command(command, timeout: timeout)
    }
    func markReady(_ id: String) { failures[id] = nil; retryDeadlines[id] = nil; ready.insert(id); publish() }
    func acquireExclusive(_ id: String) -> DeviceIdentity? {
        guard let identity = identities.first(where: { $0.id == id }) else { return nil }
        exclusive.insert(id); sessions[id]?.stopSynchronously(); sessions[id] = nil
        opened.remove(id); ready.remove(id); publish(); return identity
    }
    func releaseExclusive(_ id: String) { exclusive.remove(id); scan() }

    private func observeWake() {
        guard wakeObserver == nil else { return }
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.reconnectAfterWake() }
        }
    }

    func reconnectAfterWake() {
        sessions.values.forEach { $0.stop() }
        sessions.removeAll(); opened.removeAll(); ready.removeAll(); retryDeadlines.removeAll(); failures.removeAll()
        scan()
    }

    func reconnect(_ deviceID: String) {
        sessions[deviceID]?.stopSynchronously(); sessions[deviceID] = nil
        opened.remove(deviceID); ready.remove(deviceID); errors[deviceID] = nil
        blocked.remove(deviceID); failures[deviceID] = nil; retryDeadlines[deviceID] = nil
        scan()
    }

    nonisolated static func canReconnect(deadline: Date?, now: Date = Date()) -> Bool { deadline.map { now >= $0 } ?? true }

    func scan() {
        if let lease = leaseObserver.active() {
            if activeLeaseNonce != lease.nonce {
                sessions.values.forEach { $0.stopSynchronously() }
                sessions.removeAll(); opened.removeAll(); ready.removeAll()
                do {
                    try leaseObserver.acknowledge(lease); activeLeaseNonce = lease.nonce
                    DiagnosticsStore.record("manager.suspended", fields: ["owner_pid": String(lease.pid)])
                } catch { DiagnosticsStore.record("manager.lease_ack_failed", level: "warning") }
            }
            publish(); return
        } else if activeLeaseNonce != nil {
            activeLeaseNonce = nil; DiagnosticsStore.record("manager.resumed")
        }
        let previousPorts = Dictionary(uniqueKeysWithValues: identities.map { ($0.id, $0.port) })
        identities = defaultDiscovery ? SerialDiscovery.devices(advanced: advancedDiscovery) : discover()
        let current = Set(identities.map(\.id))
        for id in previousPorts.keys where !current.contains(id) {
            sessions[id]?.stop(); sessions[id] = nil; opened.remove(id); ready.remove(id); errors[id] = nil
            blocked.remove(id); failures[id] = nil; retryDeadlines[id] = nil
        }
        for identity in identities where sessions[identity.id]?.identity.port != identity.port {
            sessions[identity.id]?.stop(); sessions[identity.id] = nil; opened.remove(identity.id)
            if previousPorts[identity.id] != identity.port {
                ready.remove(identity.id)
                if previousPorts[identity.id] != nil { retryDeadlines[identity.id] = nil }
            }
        }
        if enabled {
            for identity in identities where identity.kind == .runtime && sessions[identity.id] == nil && !blocked.contains(identity.id)
                && !exclusive.contains(identity.id)
                && Self.canReconnect(deadline: retryDeadlines[identity.id]) {
                retryDeadlines[identity.id] = nil
                let session = DeviceSession(identity: identity, heartbeatInterval: heartbeatInterval,
                                            heartbeatTimeout: heartbeatTimeout, keychainEnabled: sessionUsesKeychain)
                session.onPrompt = { [weak self] prompt in Task { @MainActor in self?.onPrompt?(identity.id, prompt) } }
                session.onOpen = { [weak self] credentialsReady in Task { @MainActor in
                    self?.opened.insert(identity.id); if credentialsReady { self?.ready.insert(identity.id) }
                    self?.failures[identity.id] = nil; self?.retryDeadlines[identity.id] = nil
                    self?.errors[identity.id] = nil; self?.publish()
                }}
                session.onError = { [weak self] error in Task { @MainActor in
                    if (error as? DeviceError)?.blocksReconnect == true {
                        self?.blocked.insert(identity.id); self?.ready.remove(identity.id); self?.errors[identity.id] = error
                    } else if let self {
                        self.failures[identity.id, default: 0] += 1
                        let delay = self.backoff.delay(failures: self.failures[identity.id]!, random: self.random())
                        self.retryDeadlines[identity.id] = Date().addingTimeInterval(delay)
                        if self.failures[identity.id]! > 1 {
                            self.ready.remove(identity.id); self.errors[identity.id] = error
                        } else { self.errors[identity.id] = nil }
                        DiagnosticsStore.record("worker.failed", level: "warning", deviceID: identity.id,
                                                fields: ["reason": String(describing: error),
                                                         "retry_seconds": String(format: "%.3f", delay)])
                    }
                    self?.opened.remove(identity.id); self?.sessions[identity.id] = nil; self?.publish()
                }}
                sessions[identity.id] = session; session.start()
            }
        }
        publish()
    }
    private func publish() { onChange?(identities, opened, ready, errors) }
}
