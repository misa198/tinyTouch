import XCTest

final class LocalizationTests: XCTestCase {
    func testCatalogsUseTheSameShortSnakeCaseKeys() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        func strings(_ language: String) throws -> [String: String] {
            let data = try Data(contentsOf: root.appendingPathComponent("TinyTouch/\(language).lproj/Localizable.strings"))
            return try XCTUnwrap(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: String])
        }

        let english = try strings("en"), vietnamese = try strings("vi"), chinese = try strings("zh-Hans")
        XCTAssertEqual(Set(english.keys), Set(vietnamese.keys))
        XCTAssertEqual(Set(vietnamese.keys), Set(chinese.keys))
        for key in english.keys {
            XCTAssertNotNil(key.range(of: #"^[a-z][a-z0-9_]*$"#, options: .regularExpression), key)
            XCTAssertLessThanOrEqual(key.count, 48, key)
        }
        for key in [
            "fingerprint_match_login_keychain",
            "configuration_changes_device_secured",
            "device_trust_macs_independently",
            "enable_hid_background_service",
            "applying_requires_effect_immediately",
            "settings_factory_reset",
        ] {
            XCTAssertNotEqual(vietnamese[key], key)
            XCTAssertNotEqual(chinese[key], key)
        }
    }
}
