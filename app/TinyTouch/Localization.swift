import Foundation

enum AppLanguage: String, CaseIterable, Identifiable {
    case system, en, vi, zhHans = "zh-Hans"

    static let preferenceKey = "appLanguage"
    var id: Self { self }
    var locale: Locale { Locale(identifier: resolvedIdentifier) }
    var resolvedIdentifier: String {
        if self != .system { return rawValue }
        for identifier in Locale.preferredLanguages {
            let code = Locale(identifier: identifier).language.languageCode?.identifier
            if ["en", "vi"].contains(code) { return code! }
            if code == "zh" { return "zh-Hans" }
        }
        return "en"
    }
    static var saved: Self { Self(rawValue: UserDefaults.standard.string(forKey: preferenceKey) ?? "system") ?? .system }
    var title: String {
        switch self {
        case .system: L10n.text("common_system_default")
        case .en: "English"
        case .zhHans: "简体中文"
        case .vi: "Tiếng Việt"
        }
    }
}

enum L10n {
    static func text(_ key: String, _ arguments: CVarArg...) -> String {
        let language = AppLanguage.saved
        let bundle = Bundle.main.path(forResource: language.resolvedIdentifier, ofType: "lproj").flatMap(Bundle.init(path:))
        let format = bundle?.localizedString(forKey: key, value: key, table: "Localizable") ?? key
        if !arguments.isEmpty { return String(format: format, locale: language.locale, arguments: arguments) }
        if format != key { return format }
        let patterns = [
            ("ESP32-S3 ROM ", "", "esp32_s3_rom"),
            ("Serial adapter ", "", "serial_adapter"),
            ("tinyTouch ", "", "tinytouch_value"),
            ("Character ", " is unavailable in the current keyboard layout.", "character_unavailable_keyboard_layout"),
            ("Password exceeds ", " typed characters.", "password_exceeds_typed_characters"),
            ("No password is configured for fingerprint slot ", ".", "no_password_fingerprint_slot"),
            ("Invalid semantic version: ", "", "invalid_semantic_version"),
            ("Invalid app compatibility range for ", ".", "invalid_app_compatibility_range"),
            ("Duplicate firmware version ", ".", "duplicate_firmware_version"),
            ("Device error: ", "", "device_error"),
        ]
        for (prefix, suffix, formatKey) in patterns where key.hasPrefix(prefix) && key.hasSuffix(suffix) {
            let end = key.index(key.endIndex, offsetBy: -suffix.count)
            let value = String(key[key.index(key.startIndex, offsetBy: prefix.count)..<end])
            let localized = bundle?.localizedString(forKey: formatKey, value: formatKey, table: "Localizable") ?? formatKey
            return String(format: localized, locale: language.locale, value)
        }
        return key
    }

    static func deviceValue(_ value: String) -> String { deviceValue(nil, value) }

    static func deviceValue(_ key: String?, _ value: String) -> String {
        if ["submit_enter", "led_idle"].contains(key ?? ""), ["0", "1"].contains(value) {
            return text(value == "1" ? "device_value_enabled" : "device_value_disabled")
        }
        let values = ["configured", "connected", "disconnected", "error", "hid", "idle", "none", "ok", "piv", "ready", "unconfigured"]
        return values.contains(value) ? text("device_value_\(value)") : value
    }

    static func error(_ error: Error) -> String {
        switch error {
        case let error as DeviceError:
            switch error {
            case .disconnected: return text("tinytouch_disconnected")
            case .busy(let detail): return text("serial_port_flashing_tabs", detail)
            case .timeout: return text("tinytouch_not_timed_out")
            case .protocolViolation(let detail): return text("tinytouch_closed_serial_response", text(detail))
            case .response(let message): return text(message)
            case .missingCredentials: return text("mac_has_setup_first")
            case .unsupportedProtocol(let version): return text("protocol_newer_hid_credentials", version)
            case .foreignFirmware: return text("board_running_misa198_firmware")
            case .keychain(let status): return text("keychain_not_choose_retry", status)
            }
        case let error as HIDProtocolError:
            switch error {
            case .malformedEvent: return text("device_sent_hid_event")
            case .wrongKeyID: return text("hid_event_another_computer")
            case .badMAC: return text("hid_event_failed_authentication")
            case .replay: return text("replayed_hid_event_rejected")
            case .invalidKey: return text("pairing_key_invalid")
            case .password(let detail): return text(detail)
            case .crypto(let status): return text("aes_ctr_failed", status)
            }
        case let error as FirmwareError:
            switch error {
            case .invalid(let message), .flashing(let message): return text(message)
            case .checksum: return text("firmware_checksum_mismatch")
            case .noUpdate: return text("device_has_compatible_firmware")
            case .manualReset: return text("automatic_bootloader_choose_retry")
            }
        default: return error.localizedDescription
        }
    }
}
