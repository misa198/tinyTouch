import CryptoKit
import Foundation
#if SWIFT_PACKAGE
import CSerialFlasher
#endif

struct SemanticVersion: Comparable, CustomStringConvertible, Equatable {
    let major: Int, minor: Int, patch: Int
    let prerelease: [String]

    init(_ raw: String, normalizeAppVersion: Bool = false) throws {
        let value = normalizeAppVersion && raw.filter({ $0 == "." }).count == 1 ? raw + ".0" : raw
        let expression = #"^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(?:-([0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*))?(?:\+[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?$"#
        guard let match = value.wholeMatch(of: try Regex(expression)),
              let major = Int(String(match.output[1].substring!)),
              let minor = Int(String(match.output[2].substring!)),
              let patch = Int(String(match.output[3].substring!)) else {
            throw FirmwareError.invalid("Invalid semantic version: \(raw)")
        }
        self.major = major; self.minor = minor; self.patch = patch
        prerelease = match.output[4].substring.map { String($0).split(separator: ".").map(String.init) } ?? []
    }

    var description: String {
        "\(major).\(minor).\(patch)" + (prerelease.isEmpty ? "" : "-" + prerelease.joined(separator: "."))
    }

    static func < (left: Self, right: Self) -> Bool {
        let lhs = [left.major, left.minor, left.patch], rhs = [right.major, right.minor, right.patch]
        if lhs != rhs { return lhs.lexicographicallyPrecedes(rhs) }
        if left.prerelease.isEmpty || right.prerelease.isEmpty { return !left.prerelease.isEmpty && right.prerelease.isEmpty }
        for (a, b) in zip(left.prerelease, right.prerelease) where a != b {
            if let ai = Int(a), let bi = Int(b) { return ai < bi }
            if Int(a) != nil { return true }
            if Int(b) != nil { return false }
            return a < b
        }
        return left.prerelease.count < right.prerelease.count
    }
}

enum FirmwareStrategy: String, Equatable { case ota = "OTA", factory = "factory_flash_plain" }

struct FirmwareChannelRelease: Codable, Equatable {
    let version: String
    let minAppVersion: String
    let maxAppVersionExclusive: String
    let manifest: URL
}

struct FirmwareChannel: Codable {
    let schema: Int
    let releases: [FirmwareChannelRelease]

    static func decode(_ data: Data, appVersion: String) throws -> FirmwareChannelRelease {
        let channel = try JSONDecoder().decode(Self.self, from: data)
        guard channel.schema == 1, !channel.releases.isEmpty else { throw FirmwareError.invalid("unsupported_empty_firmware_channel") }
        let app = try SemanticVersion(appVersion, normalizeAppVersion: true)
        var versions = Set<String>(), compatible: [(SemanticVersion, FirmwareChannelRelease)] = []
        for release in channel.releases {
            let version = try SemanticVersion(release.version)
            let minimum = try SemanticVersion(release.minAppVersion)
            let maximum = try SemanticVersion(release.maxAppVersionExclusive)
            guard minimum < maximum else { throw FirmwareError.invalid("Invalid app compatibility range for \(release.version).") }
            guard release.manifest.scheme == "https", release.manifest.host != nil else { throw FirmwareError.invalid("firmware_manifest_use_https") }
            guard versions.insert(version.description).inserted else { throw FirmwareError.invalid("Duplicate firmware version \(release.version).") }
            if minimum <= app && app < maximum { compatible.append((version, release)) }
        }
        guard let selected = compatible.max(by: { $0.0 < $1.0 })?.1 else { throw FirmwareError.invalid("no_firmware_app_version") }
        return selected
    }
}

struct FirmwareAsset: Codable, Equatable { let file: String; let size: Int; let sha256: String }
struct FirmwareLayout: Codable { let version: String; let fullImage: FirmwareAsset }
struct FirmwareLayouts: Codable { let factory: FirmwareLayout }
struct FirmwareReleaseManifest: Codable {
    let productID: String
    let version: String
    let protocolVersion: Int
    let boards: [String]
    let firmware: FirmwareLayouts
    let ota: FirmwareAsset
    enum CodingKeys: String, CodingKey { case productID = "product", version, protocolVersion = "protocol", boards, firmware, ota }
}

struct FirmwareUpdate: Equatable {
    let version: SemanticVersion
    let strategy: FirmwareStrategy
    let manifestURL: URL
    let asset: FirmwareAsset
    var assetURL: URL { URL(string: asset.file, relativeTo: manifestURL)!.absoluteURL }
}

enum FirmwareError: Error, LocalizedError {
    case invalid(String), checksum, noUpdate, manualReset, flashing(String)
    var errorDescription: String? {
        switch self {
        case .invalid(let message), .flashing(let message): message
        case .checksum: "firmware_checksum_mismatch"
        case .noUpdate: "device_has_compatible_firmware"
        case .manualReset: "automatic_bootloader_choose_retry"
        }
    }
}

enum FirmwareSupport {
    static let channelURL = URL(string: "https://raw.githubusercontent.com/misa198/tinyTouch/master/channels/app-firmware.json")!
    static let supportedBoards = Set(["esp32s3-super-mini", "seeed-xiao-esp32s3"])

    static func strategy(for identity: DeviceIdentity, status: DeviceStatus?) -> FirmwareStrategy {
        identity.kind == .runtime && status?.protocolVersion == 6 ? .ota : .factory
    }

    static func update(channelData: Data, manifestData: Data, manifestURL: URL,
                       appVersion: String, identity: DeviceIdentity, status: DeviceStatus?) throws -> FirmwareUpdate {
        let release = try FirmwareChannel.decode(channelData, appVersion: appVersion)
        guard release.manifest == manifestURL else { throw FirmwareError.invalid("firmware_manifest_changed_unexpectedly") }
        let manifest = try JSONDecoder().decode(FirmwareReleaseManifest.self, from: manifestData)
        let version = try SemanticVersion(release.version)
        guard manifest.productID == DeviceStatus.productID,
              manifest.version == release.version, manifest.firmware.factory.version == release.version,
              manifest.protocolVersion == 6 else { throw FirmwareError.invalid("release_manifest_protocol_inconsistent") }
        guard !supportedBoards.isDisjoint(with: manifest.boards) else { throw FirmwareError.invalid("release_not_s3_board") }
        if let current = status.flatMap({ try? SemanticVersion($0.firmwareVersion) }), version <= current { throw FirmwareError.noUpdate }
        let strategy = strategy(for: identity, status: status)
        let asset = strategy == .ota ? manifest.ota : manifest.firmware.factory.fullImage
        guard asset.size > 0, asset.size <= 4 * 1024 * 1024,
              asset.sha256.count == 64, asset.sha256.allSatisfy({ $0.isNumber || ("a"..."f").contains(String($0)) }),
              !asset.file.isEmpty, !asset.file.contains("/"),
              let url = URL(string: asset.file, relativeTo: manifestURL)?.absoluteURL,
              url.scheme == "https", url.host == manifestURL.host else {
            throw FirmwareError.invalid("firmware_asset_metadata_unsafe")
        }
        return FirmwareUpdate(version: version, strategy: strategy, manifestURL: manifestURL, asset: asset)
    }

    static func verifiedDownload(_ update: FirmwareUpdate, session: URLSession = .shared) async throws -> Data {
        let (data, response) = try await session.data(from: update.assetURL)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw FirmwareError.invalid("firmware_server_returned_error") }
        try verify(data, asset: update.asset)
        return data
    }

    static func verify(_ data: Data, asset: FirmwareAsset) throws {
        guard data.count == asset.size,
              SHA256.hash(data: data).map({ String(format: "%02x", $0) }).joined() == asset.sha256 else {
            throw FirmwareError.checksum
        }
    }

    static func ota(image: Data, digest: String,
                    command: (String, TimeInterval) async throws -> [String],
                    progress: @MainActor (Double) -> Void) async throws {
        var generator = SystemRandomNumberGenerator()
        let token = (0..<16).map { _ in String(format: "%02x", UInt8.random(in: .min ... .max, using: &generator)) }.joined()
        _ = try await command("AUTH", 20)
        var offset = try next(try await command("OTA BEGIN \(token) \(image.count) \(digest)", 10))
        while offset < image.count {
            let end = min(offset + 360, image.count)
            let payload = image[offset..<end].base64EncodedString()
            offset = try next(try await command("OTA WRITE \(token) \(offset) \(payload)", 10))
            await progress(Double(offset) / Double(image.count))
        }
        guard try await command("OTA COMMIT \(token)", 15).contains(where: { $0.hasPrefix("OK OTA STAGED") && $0.contains("power_cycle=required") }) else {
            throw FirmwareError.invalid("device_not_ota_image")
        }
    }

    private static func next(_ lines: [String]) throws -> Int {
        for line in lines.reversed() where line.hasPrefix("OK OTA ") {
            if let field = line.split(separator: " ").first(where: { $0.hasPrefix("next=") }),
               let value = Int(field.dropFirst(5)) { return value }
        }
        throw FirmwareError.invalid("device_returned_ota_offset")
    }
}

private final class FlashProgressBox: @unchecked Sendable {
    let callback: @MainActor (Double) -> Void
    init(_ callback: @escaping @MainActor (Double) -> Void) { self.callback = callback }
}

enum FirmwareFlasher {
    static func flash(port: String, imageURL: URL, manualBoot: Bool,
                      progress: @escaping @MainActor (Double) -> Void) async throws {
        try await Task.detached {
            let box = Unmanaged.passRetained(FlashProgressBox(progress))
            defer { box.release() }
            var buffer = [CChar](repeating: 0, count: 256)
            let result = port.withCString { serial in
                imageURL.path.withCString { image in
                    tt_flash_factory(serial, image, manualBoot, { value, context in
                        guard let context else { return }
                        let callback = Unmanaged<FlashProgressBox>.fromOpaque(context).takeUnretainedValue().callback
                        Task { @MainActor in callback(value) }
                    }, box.toOpaque(), &buffer, buffer.count)
                }
            }
            guard result == TT_FLASH_OK else {
                if result == TT_FLASH_CONNECT && !manualBoot { throw FirmwareError.manualReset }
                throw FirmwareError.flashing(String(cString: buffer))
            }
        }.value
    }
}
