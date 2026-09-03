import CommonCrypto
import Carbon.HIToolbox
import CryptoKit
import Foundation
import Security

enum HIDProtocolError: Error, LocalizedError, Equatable {
    case malformedEvent, wrongKeyID, badMAC, replay, invalidKey, password(String), crypto(Int32)

    var errorDescription: String? {
        switch self {
        case .malformedEvent: "The device sent a malformed HID event."
        case .wrongKeyID: "The HID event belongs to another computer."
        case .badMAC: "The HID event failed authentication."
        case .replay: "A replayed HID event was rejected."
        case .invalidKey: "The pairing key is invalid."
        case .password(let detail): detail
        case .crypto(let status): "AES-CTR failed (\(status))."
        }
    }
}

struct ReplayState: Codable, Equatable {
    var seenNonces: [String] = []

    enum CodingKeys: String, CodingKey { case seenNonces = "seen_nonces" }

    mutating func accept(_ nonce: String) throws {
        let normalized = nonce.lowercased()
        guard !seenNonces.contains(where: { $0.lowercased() == normalized }) else { throw HIDProtocolError.replay }
        seenNonces.append(normalized)
        if seenNonces.count > 256 { seenNonces.removeFirst(seenNonces.count - 256) }
    }
}

struct ReplayStateStore {
    var directory: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("misa198.TinyTouch", isDirectory: true)

    func load(deviceID: String) -> ReplayState {
        guard let data = try? Data(contentsOf: path(deviceID)),
              let state = try? JSONDecoder().decode(ReplayState.self, from: data) else { return ReplayState() }
        return ReplayState(seenNonces: state.seenNonces.suffix(256).map { $0.lowercased() })
    }

    func save(_ state: ReplayState, deviceID: String) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(state).write(to: path(deviceID), options: .atomic)
    }

    func remove(deviceID: String) throws {
        let url = path(deviceID)
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
    }

    private func path(_ deviceID: String) -> URL {
        directory.appendingPathComponent("state-\(DeviceIdentity.normalize(deviceID)).json")
    }
}

struct HIDResponse: Equatable {
    let line: String
    let nonce: String
    let slot: Int
}

enum KeyboardMode: String, Codable, CaseIterable, Identifiable {
    case auto, us
    var id: Self { self }
    var title: String { self == .auto ? "Current keyboard layout" : "US keyboard" }
}

struct KeyboardSettings: Codable, Equatable {
    var keyboardLayout = KeyboardMode.auto
    enum CodingKeys: String, CodingKey { case keyboardLayout = "keyboard_layout" }
}

struct KeyboardSettingsStore {
    var directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("misa198.TinyTouch", isDirectory: true)

    func load(deviceID: String) -> KeyboardSettings {
        guard let data = try? Data(contentsOf: path(deviceID)),
              let value = try? JSONDecoder().decode(KeyboardSettings.self, from: data) else { return KeyboardSettings() }
        return value
    }

    func save(_ value: KeyboardSettings, deviceID: String) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(value).write(to: path(deviceID), options: .atomic)
    }

    func remove(deviceID: String) throws {
        let url = path(deviceID)
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
    }

    func path(_ deviceID: String) -> URL {
        directory.appendingPathComponent("settings-\(DeviceIdentity.normalize(deviceID)).json")
    }
}

enum KeyboardMapper {
    static let maximumPasswordBytes = 160
    private static let keyCodes: [Character: UInt16] = [
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8,
        "v": 9, "b": 11, "q": 12, "w": 13, "e": 14, "r": 15, "y": 16, "t": 17,
        "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23, "=": 24, "9": 25,
        "7": 26, "-": 27, "8": 28, "0": 29, "]": 30, "o": 31, "u": 32, "[": 33,
        "i": 34, "p": 35, "l": 37, "j": 38, "'": 39, "k": 40, ";": 41, "\\": 42,
        ",": 43, "/": 44, "n": 45, "m": 46, ".": 47, " ": 49, "`": 50,
    ]
    private static let shifted = Dictionary(uniqueKeysWithValues: zip(
        Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ!@#$%^&*()_+{}|:\"<>?~"),
        Array("abcdefghijklmnopqrstuvwxyz1234567890-=[]\\;',./`")
    ))

    static func translate(_ password: Data, mode: KeyboardMode, outputMap: [Character: Character]? = nil) throws -> Data {
        let result: Data
        switch mode {
        case .us:
            guard password.allSatisfy({ $0 < 0x80 }) else {
                throw HIDProtocolError.password("The password contains a character unavailable to the US HID keyboard.")
            }
            result = password
        case .auto:
            guard let text = String(data: password, encoding: .utf8) else {
                throw HIDProtocolError.password("The password is not valid UTF-8.")
            }
            let map = try outputMap ?? currentOutputMap()
            var wire = ""
            for character in text {
                guard let mapped = map[character] else {
                    throw HIDProtocolError.password("Character \(String(reflecting: character)) is unavailable in the current keyboard layout.")
                }
                wire.append(mapped)
            }
            result = Data(wire.utf8)
        }
        guard result.count <= maximumPasswordBytes else {
            throw HIDProtocolError.password("Password exceeds \(maximumPasswordBytes) typed characters.")
        }
        return result
    }

    static func currentOutputMap() throws -> [Character: Character] {
        guard let source = TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue(),
              let raw = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else {
            throw HIDProtocolError.password("macOS did not provide a usable keyboard layout.")
        }
        let data = unsafeBitCast(raw, to: CFData.self)
        guard let bytes = CFDataGetBytePtr(data) else {
            throw HIDProtocolError.password("The current keyboard layout has no Unicode key map.")
        }
        let layout = UnsafeRawPointer(bytes).assumingMemoryBound(to: UCKeyboardLayout.self)
        var result: [Character: Character] = [:]
        for scalar in UInt8(32)...UInt8(126) {
            let wire = Character(UnicodeScalar(scalar))
            let base = shifted[wire] ?? wire
            guard let code = keyCodes[Character(String(base).lowercased())] else { continue }
            var deadKey: UInt32 = 0, length = 0
            var characters = [UniChar](repeating: 0, count: 4)
            let status = UCKeyTranslate(layout, code, UInt16(kUCKeyActionDown),
                shifted[wire] == nil ? 0 : UInt32(shiftKey >> 8), UInt32(LMGetKbdType()), 0,
                &deadKey, characters.count, &length, &characters)
            if status == noErr, length == 1, deadKey == 0,
               let output = UnicodeScalar(characters[0]).map(Character.init) { result[output] = wire }
        }
        return result
    }
}

enum HIDProtocol {
    static func keyID(_ key: Data) throws -> String {
        guard key.count == 32 else { throw HIDProtocolError.invalidKey }
        return Data(SHA256.hash(data: key).prefix(8)).hex
    }

    static func response(
        to line: String,
        passwords: [Int: Data],
        pairingKey: Data,
        state: ReplayState,
        keyboardMode: KeyboardMode = .us,
        keyboardMap: [Character: Character]? = nil,
        iv suppliedIV: Data? = nil
    ) throws -> HIDResponse? {
        guard line.utf8.count <= 2_048 else { throw HIDProtocolError.malformedEvent }
        let parts = line.split(separator: " ").map(String.init)
        guard let kind = parts.first, kind == "EV" || kind == "EV2" else { return nil }
        guard pairingKey.count == 32 else { throw HIDProtocolError.invalidKey }

        let nonce: String
        let material: String
        let responseKind: String
        let counter: UInt64, slot: Int, score: UInt32
        guard parts.count >= 5, parts[2].allSatisfy(\.isNumber), parts[3].allSatisfy(\.isNumber),
              parts[4].allSatisfy(\.isNumber), let parsedCounter = UInt64(parts[2]),
              let parsedSlot = Int(parts[3]), (1...5).contains(parsedSlot),
              let parsedScore = UInt32(parts[4]), parsedScore <= UInt32(Int32.max) else {
            throw HIDProtocolError.malformedEvent
        }
        counter = parsedCounter; slot = parsedSlot; score = parsedScore
        _ = counter; _ = score
        if kind == "EV" {
            guard parts.count == 6 else { throw HIDProtocolError.malformedEvent }
            nonce = parts[1]
            material = "EV|\(nonce)|\(parts[2])|\(parts[3])|\(parts[4])"
            try authenticate(parts[5], material: material, key: pairingKey)
            responseKind = "PW"
        } else {
            guard (6...13).contains(parts.count) else { throw HIDProtocolError.malformedEvent }
            nonce = parts[1]
            let id = try keyID(pairingKey)
            var authenticators: [String: String] = [:]
            for item in parts[5...] {
                let pair = item.split(separator: ":", maxSplits: 1).map(String.init)
                guard pair.count == 2, Data(strictHex: pair[0], count: 8) != nil,
                      Data(strictHex: pair[1], count: 32) != nil else { throw HIDProtocolError.malformedEvent }
                let identifier = pair[0].lowercased()
                guard authenticators[identifier] == nil else { throw HIDProtocolError.malformedEvent }
                authenticators[identifier] = pair[1].lowercased()
            }
            guard let authenticator = authenticators[id] else {
                throw HIDProtocolError.wrongKeyID
            }
            material = "EV2|\(id)|\(nonce)|\(parts[2])|\(parts[3])|\(parts[4])"
            try authenticate(authenticator, material: material, key: pairingKey)
            responseKind = "PW2 \(id)"
        }
        guard Data(strictHex: nonce, count: 16) != nil else { throw HIDProtocolError.malformedEvent }
        guard !state.seenNonces.contains(where: { $0.lowercased() == nonce.lowercased() }) else { throw HIDProtocolError.replay }
        guard let password = passwords[slot] ?? passwords[0] else {
            throw HIDProtocolError.password("No password is configured for fingerprint slot \(slot).")
        }
        let wirePassword = try KeyboardMapper.translate(password, mode: keyboardMode, outputMap: keyboardMap)

        let iv = try suppliedIV ?? random(count: 16)
        guard iv.count == 16 else { throw HIDProtocolError.malformedEvent }
        let sessionKey = hmac(key: pairingKey, message: "SESSION|\(nonce)")
        let ciphertext = try aesCTR(key: sessionKey, iv: iv, input: wirePassword)
        let base = "\(responseKind) \(nonce) \(iv.hex) \(ciphertext.hex)"
        let macMaterial = base.replacingOccurrences(of: " ", with: "|")
        return HIDResponse(line: "\(base) \(hmac(key: pairingKey, message: macMaterial).hex)\n",
                           nonce: nonce.lowercased(), slot: slot)
    }

    static func deliver(_ response: HIDResponse, state: inout ReplayState, store: ReplayStateStore,
                        deviceID: String, write: (String) throws -> Void) throws {
        try write(response.line)
        try state.accept(response.nonce)
        try store.save(state, deviceID: deviceID)
    }

    static func aesCTR(key: Data, iv: Data, input: Data) throws -> Data {
        guard [16, 24, 32].contains(key.count), iv.count == 16 else { throw HIDProtocolError.invalidKey }
        var cryptor: CCCryptorRef?
        let createStatus = key.withUnsafeBytes { keyBytes in
            iv.withUnsafeBytes { ivBytes in
                CCCryptorCreateWithMode(
                    CCOperation(kCCEncrypt), CCMode(kCCModeCTR), CCAlgorithm(kCCAlgorithmAES),
                    CCPadding(ccNoPadding), ivBytes.baseAddress, keyBytes.baseAddress, key.count,
                    nil, 0, 0, CCModeOptions(kCCModeOptionCTR_BE), &cryptor
                )
            }
        }
        guard createStatus == kCCSuccess, let cryptor else { throw HIDProtocolError.crypto(createStatus) }
        defer { CCCryptorRelease(cryptor) }
        if input.isEmpty { return Data() }
        var output = Data(count: input.count)
        var moved = 0
        let outputCount = output.count
        let updateStatus = output.withUnsafeMutableBytes { outputBytes in
            input.withUnsafeBytes { inputBytes in
                CCCryptorUpdate(cryptor, inputBytes.baseAddress, input.count,
                                outputBytes.baseAddress, outputCount, &moved)
            }
        }
        guard updateStatus == kCCSuccess, moved == input.count else { throw HIDProtocolError.crypto(updateStatus) }
        return output.prefix(moved)
    }

    private static func authenticate(_ supplied: String, material: String, key: Data) throws {
        guard let suppliedData = Data(strictHex: supplied, count: 32),
              constantTimeEqual(suppliedData, hmac(key: key, message: material)) else {
            throw HIDProtocolError.badMAC
        }
    }

    private static func hmac(key: Data, message: String) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: Data(message.utf8), using: SymmetricKey(data: key)))
    }

    private static func constantTimeEqual(_ lhs: Data, _ rhs: Data) -> Bool {
        guard lhs.count == rhs.count else { return false }
        return zip(lhs, rhs).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
    }

    private static func random(count: Int) throws -> Data {
        var data = Data(count: count)
        let status = data.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, count, $0.baseAddress!) }
        guard status == errSecSuccess else { throw HIDProtocolError.crypto(status) }
        return data
    }
}

extension Data {
    init?(strictHex value: String, count: Int? = nil) {
        guard value.count.isMultiple(of: 2), count == nil || value.count == count! * 2 else { return nil }
        var result = Data(capacity: value.count / 2)
        var index = value.startIndex
        while index < value.endIndex {
            let next = value.index(index, offsetBy: 2)
            guard let byte = UInt8(value[index..<next], radix: 16) else { return nil }
            result.append(byte); index = next
        }
        self = result
    }

    var hex: String { map { String(format: "%02x", $0) }.joined() }
}
