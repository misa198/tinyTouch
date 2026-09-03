import AppKit
import Combine
import Foundation
import Security
import ServiceManagement
import SwiftUI

enum ConnectionState: String { case disconnected, connected, ready, error }

struct DeviceViewState: Identifiable {
    var identity: DeviceIdentity
    var status: DeviceStatus?
    var connection: ConnectionState
    var hostIDs: [String] = []
    var hostCapacity = 0
    var currentMacID: String?
    var message: String?
    var isError = false
    var id: String { identity.id }
    var name: String { identity.name }
}

@MainActor
final class AppState: ObservableObject {
    @Published var devices: [DeviceViewState] = []
    @Published var selectedID: String?
    @Published var busy = false
    @Published var appMessage: String?
    @Published var appMessageIsError = false
    @Published private(set) var backgroundEnabled: Bool
    @Published private(set) var launchAtLogin: Bool
    @Published private(set) var legacyHelperDetected: Bool
    @Published private(set) var legacyOwners: [PortOwner] = []
    @Published private(set) var onboardingComplete: Bool
    @Published private(set) var keyboardMode = KeyboardMode.auto

    private let manager = DeviceManager(), defaults = UserDefaults.standard
    private var window: NSWindow?, windowCloseObserver: NSObjectProtocol?, knownOpened: Set<String> = []
    private let legacyPlist = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/LaunchAgents/com.tinytouch.helper.plist")

    var selectedDevice: DeviceViewState? { devices.first { $0.id == selectedID } }
    var summary: String {
        if let error = devices.first(where: { $0.connection == .error }) { return "Error — \(error.name)" }
        let ready = devices.filter { $0.connection == .ready }.count
        if ready > 0 { return ready == 1 ? "HID ready" : "HID ready on \(ready) devices" }
        return devices.isEmpty ? "No tinyTouch connected" : "tinyTouch connected"
    }
    var menuIcon: String {
        if devices.contains(where: { $0.connection == .error }) { return "exclamationmark.triangle.fill" }
        return devices.isEmpty ? "lock" : "lock.fill"
    }

    init() {
        onboardingComplete = defaults.bool(forKey: "onboardingComplete")
        backgroundEnabled = defaults.object(forKey: "backgroundEnabled") as? Bool ?? true
        launchAtLogin = SMAppService.mainApp.status == .enabled
        legacyHelperDetected = FileManager.default.fileExists(atPath: legacyPlist.path) || Self.legacyJobLoaded()
        if legacyHelperDetected { legacyOwners = LegacyProcessInspector.owners(ports: SerialDiscovery.devices().map(\.port)) }
        manager.onPrompt = { [weak self] id, prompt in self?.showPrompt(prompt, deviceID: id) }
        manager.onChange = { [weak self] identities, opened, ready, errors in
            self?.update(identities, opened: opened, ready: ready, errors: errors)
        }
        manager.start(enabled: backgroundEnabled && !legacyHelperDetected)
        if !onboardingComplete { DispatchQueue.main.async { [weak self] in self?.showWindow() } }
    }

    func showWindow() {
        // Let the MenuBarExtra menu dismiss before activating its window.
        DispatchQueue.main.async { [self] in
            NSApp.setActivationPolicy(.regular)
            if window == nil {
                let controller = NSHostingController(rootView: ContentView().environmentObject(self))
                let newWindow = NSWindow(contentViewController: controller)
                newWindow.title = "TinyTouch"; newWindow.setContentSize(NSSize(width: 800, height: 540))
                newWindow.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
                newWindow.titleVisibility = .hidden; newWindow.titlebarAppearsTransparent = true
                newWindow.titlebarSeparatorStyle = .none; newWindow.isMovableByWindowBackground = true
                newWindow.center(); window = newWindow
                windowCloseObserver = NotificationCenter.default.addObserver(
                    forName: NSWindow.willCloseNotification, object: newWindow, queue: .main
                ) { [weak self] _ in
                    Task { @MainActor in self?.windowDidClose() }
                }
            }
            if window?.isMiniaturized == true { window?.deminiaturize(nil) }
            NSApp.activate(ignoringOtherApps: true); window?.makeKeyAndOrderFront(nil)
        }
    }

    private func windowDidClose() {
        window = nil
        if let windowCloseObserver { NotificationCenter.default.removeObserver(windowCloseObserver) }
        windowCloseObserver = nil
        NSApp.setActivationPolicy(.accessory)
    }

    func setBackgroundEnabled(_ enabled: Bool) {
        backgroundEnabled = enabled; defaults.set(enabled, forKey: "backgroundEnabled")
        manager.setEnabled(enabled && !legacyHelperDetected)
        setAppMessage(enabled ? "HID service enabled." : "HID service paused.")
    }
    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            launchAtLogin = enabled; defaults.set(enabled, forKey: "launchAtLogin")
        } catch { failApp(error) }
    }
    func completeOnboarding(launchAtLogin: Bool, replaceLegacy: Bool) {
        if replaceLegacy && legacyHelperDetected { replaceLegacyHelper() }
        setLaunchAtLogin(launchAtLogin); onboardingComplete = true; defaults.set(true, forKey: "onboardingComplete")
    }

    func refresh() {
        guard let id = selectedID else { return }
        if selectedDevice?.connection == .error {
            if let index = devices.firstIndex(where: { $0.id == id }) {
                devices[index].status = nil; devices[index].hostIDs = []; devices[index].hostCapacity = 0
                devices[index].currentMacID = nil
            }
            clearDeviceMessage(id); manager.retry(id); return
        }
        perform(deviceID: id) { [self] in try await readStatus(id: id); return "Status updated." }
    }

    func configureHID(password: String, confirmation: String, enroll: Bool) {
        guard !password.isEmpty else { failSelected(DeviceError.response("Password cannot be empty.")); return }
        guard password == confirmation else { failSelected(DeviceError.response("Passwords do not match.")); return }
        guard let id = selectedID else { return }
        perform(deviceID: id) { [self] in
            var status = try await status(id: id)
            guard status.isCompatible else { throw DeviceError.unsupportedProtocol(status.protocolVersion) }
            guard status.mode == "hid" else { throw DeviceError.response("Switch tinyTouch to HID mode outside this app, then try again.") }
            guard status.sensorReady else { throw DeviceError.response("The fingerprint sensor is not responding.") }
            let mode = KeyboardSettingsStore().load(deviceID: id).keyboardLayout
            _ = try KeyboardMapper.translate(Data(password.utf8), mode: mode)
            try await unlock(id, dialect: status.dialect)
            let existingKey = try await pairingKey(id)
            let key: Data
            if let existingKey { key = existingKey } else { key = try await randomKeyOffMain() }
            if status.protocolVersion >= 2 {
                let hosts = try await hostList(id), keyID = try await keyID(key)
                if !hosts.ids.contains(keyID) {
                    guard hosts.capacity == 0 || hosts.ids.count < hosts.capacity else {
                        throw DeviceError.response("The device already trusts its maximum number of HID computers.")
                    }
                    _ = try await manager.command(deviceID: id, status.dialect.hostAdd(id: keyID, key: key.hex))
                }
            } else {
                if status.hidKeyConfigured && existingKey == nil {
                    throw DeviceError.response("Legacy single-computer HID is paired to another Mac. Update firmware before adding this Mac.")
                }
                if !status.hidKeyConfigured { _ = try await manager.command(deviceID: id, "HID_KEY \(key.hex)") }
            }
            try await saveCredentials(key: key, password: password, id: id); manager.markReady(id)
            if status.fingerprintCount == 0 && enroll {
                for slot in status.dialect == .protocol6 ? Array(1...4) : [1] {
                    _ = try await manager.command(deviceID: id, status.dialect.enroll(slot: slot), timeout: 50)
                }
            }
            status = try await readStatus(id: id)
            return "HID is ready. Your credentials were saved to Keychain after device confirmation."
        }
    }

    func enroll(slot: Int) { mutateFingerprint({ $0.enroll(slot: slot) }, success: "Fingerprint enrolled in slot \(slot).", timeout: 50) }
    func deleteFingerprint(slot: Int) { mutateFingerprint({ $0.delete(slot: slot) }, success: "Fingerprint slot \(slot) deleted.") }
    func deleteAllFingerprints() { mutateFingerprint({ $0.clear }, success: "All fingerprints deleted.") }
    func refreshComputers() {
        guard let id = selectedID else { return }
        perform(deviceID: id) { [self] in try await readComputers(id: id); return "Computer list updated." }
    }
    func addCurrentMac() {
        guard let id = selectedID else { return }
        perform(deviceID: id) { [self] in
            guard let key = try await pairingKey(id), try await hasPassword(id) else { throw DeviceError.missingCredentials }
            let status = try await status(id: id)
            guard status.isCompatible, status.protocolVersion >= 2 else {
                throw DeviceError.response("This firmware supports only one HID computer.")
            }
            try await unlock(id, dialect: status.dialect)
            let hosts = try await hostList(id, dialect: status.dialect), keyID = try await keyID(key)
            if !hosts.ids.contains(keyID) {
                guard hosts.capacity == 0 || hosts.ids.count < hosts.capacity else { throw DeviceError.response("The HID computer list is full.") }
                _ = try await manager.command(deviceID: id, status.dialect.hostAdd(id: keyID, key: key.hex))
            }
            try await readComputers(id: id); return "This Mac is trusted for HID."
        }
    }
    func removeComputer(id hostID: String) {
        guard let deviceID = selectedID, Data(strictHex: hostID, count: 8) != nil else { return }
        perform(deviceID: deviceID) { [self] in
            let status = try await status(id: deviceID)
            try await unlock(deviceID, dialect: status.dialect)
            _ = try await manager.command(deviceID: deviceID, status.dialect.hostRemove(id: hostID.lowercased()))
            try await readComputers(id: deviceID); return "Computer removed."
        }
    }

    func setKeyboardMode(_ mode: KeyboardMode) {
        guard let id = selectedID else { return }
        do {
            try KeyboardSettingsStore().save(KeyboardSettings(keyboardLayout: mode), deviceID: id)
            keyboardMode = mode; setAppMessage("Keyboard layout saved for \(id).")
        } catch { failApp(error) }
    }

    func exportDiagnostics() {
        let panel = NSSavePanel(); panel.nameFieldStringValue = "TinyTouch-Diagnostics.json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try DiagnosticsStore.export(to: url, devices: devices.map(\.identity), states: [
                "background_enabled": String(backgroundEnabled), "launch_at_login": String(launchAtLogin),
                "device_count": String(devices.count), "legacy_helper_detected": String(legacyHelperDetected),
            ])
            setAppMessage("Diagnostics exported.")
        } catch { failApp(error) }
    }

    func replaceLegacyHelper() {
        guard !busy else { return }
        busy = true; manager.setEnabled(false); setAppMessage("Waiting for the legacy helper to release tinyTouch…")
        let plist = legacyPlist, ports = SerialDiscovery.devices().map(\.port)
        Task {
            let remaining = await Task.detached { () -> [PortOwner] in
                if FileManager.default.fileExists(atPath: plist.path) {
                    _ = LegacyProcessInspector.run("/bin/launchctl", ["bootout", "gui/\(getuid())", plist.path])
                }
                let owners = LegacyProcessInspector.owners(ports: ports)
                owners.filter(\.isLegacyHelper).forEach { _ = Darwin.kill($0.pid, SIGTERM) }
                return LegacyProcessInspector.waitForRelease(timeout: 6) { LegacyProcessInspector.owners(ports: ports) }
            }.value
            legacyOwners = remaining
            if remaining.isEmpty {
                do {
                    if FileManager.default.fileExists(atPath: plist.path) { try FileManager.default.removeItem(at: plist) }
                    legacyHelperDetected = false; manager.setEnabled(backgroundEnabled)
                    setAppMessage("Legacy helper removed. Keychain credentials and replay state were preserved.")
                } catch { failApp(error) }
            } else {
                legacyHelperDetected = true
                failApp(DeviceError.response("Serial port is still held by \(remaining.map(\.detail).joined(separator: "; ")). Close it, then choose Replace again."))
            }
            busy = false
        }
    }

    private func update(_ identities: [DeviceIdentity], opened: Set<String>, ready: Set<String>, errors: [String: Error]) {
        let previous = Dictionary(uniqueKeysWithValues: devices.map { ($0.id, $0) })
        let newlyOpened = opened.subtracting(knownOpened); knownOpened = opened
        devices = identities.map { identity in
            var device = previous[identity.id] ?? DeviceViewState(identity: identity, connection: .connected)
            device.identity = identity
            device.connection = errors[identity.id] != nil || device.status?.isCompatible == false
                ? .error : (ready.contains(identity.id) ? .ready : .connected)
            if let error = errors[identity.id] { device.message = error.localizedDescription; device.isError = true }
            else if newlyOpened.contains(identity.id), device.connection != .error { device.message = nil; device.isError = false }
            return device
        }
        if selectedID == nil || !identities.contains(where: { $0.id == selectedID }) { selectedID = identities.first?.id }
        if let selectedID { keyboardMode = KeyboardSettingsStore().load(deviceID: selectedID).keyboardLayout }
        for id in newlyOpened {
            Task { do { try await readStatus(id: id) } catch { fail(error, deviceID: id) } }
        }
    }

    @discardableResult private func readStatus(id: String) async throws -> DeviceStatus {
        let value = try await status(id: id)
        if let index = devices.firstIndex(where: { $0.id == id }) {
            devices[index].status = value
            if !value.isCompatible {
                devices[index].connection = .error; devices[index].message = DeviceError.unsupportedProtocol(value.protocolVersion).localizedDescription
                devices[index].isError = true
            }
        }
        guard value.isCompatible else { return value }
        if value.protocolVersion >= 2 {
            let hosts = try await hostList(id, dialect: value.dialect)
            let migrated = try await Task.detached {
                try CredentialMigrator.migrateIfProven(deviceID: id, hostIDs: hosts.ids)
            }.value
            if migrated,
               try await hasPassword(id, background: true), try await pairingKey(id, background: true) != nil { manager.markReady(id) }
            try await readComputers(id: id, hosts: hosts)
        }
        else if let index = devices.firstIndex(where: { $0.id == id }) {
            devices[index].hostIDs = []; devices[index].hostCapacity = 0; devices[index].currentMacID = nil
        }
        return value
    }
    private func status(id: String) async throws -> DeviceStatus {
        let lines = try await manager.command(deviceID: id, "STATUS")
        guard let line = lines.last(where: { $0.hasPrefix("OK STATUS ") }) else { throw DeviceError.response("No STATUS response received.") }
        return try DeviceStatus(line: line)
    }
    private func hostList(_ id: String, dialect: DeviceDialect? = nil) async throws -> HIDHostList {
        let deviceStatus = dialect == nil ? try await status(id: id) : nil
        let resolved = dialect ?? deviceStatus!.dialect
        guard resolved != .unsupported else { throw DeviceError.unsupportedProtocol(deviceStatus?.protocolVersion ?? 0) }
        let lines = try await manager.command(deviceID: id, resolved.hostList)
        guard let line = lines.last(where: { $0.hasPrefix("OK HID_KEY_IDS ") || $0.hasPrefix("OK HOST LIST ") })
        else { throw DeviceError.response("No computer list received.") }
        return try HIDHostList(line: line)
    }
    private func readComputers(id: String, hosts supplied: HIDHostList? = nil) async throws {
        let hosts: HIDHostList
        if let supplied { hosts = supplied } else { hosts = try await hostList(id) }
        let macID = try await pairingKey(id, background: true).map { try HIDProtocol.keyID($0) }
        if let index = devices.firstIndex(where: { $0.id == id }) {
            devices[index].hostIDs = hosts.ids; devices[index].hostCapacity = hosts.capacity; devices[index].currentMacID = macID
        }
    }
    private func unlock(_ id: String, dialect: DeviceDialect? = nil) async throws {
        let resolved: DeviceDialect
        if let dialect { resolved = dialect } else { resolved = try await status(id: id).dialect }
        _ = try await manager.command(deviceID: id, resolved.unlock, timeout: 20)
    }
    private func mutateFingerprint(_ command: @escaping (DeviceDialect) -> String, success: String, timeout: TimeInterval = 20) {
        guard let id = selectedID else { return }
        perform(deviceID: id) { [self] in
            let status = try await status(id: id)
            guard status.isCompatible else { throw DeviceError.unsupportedProtocol(status.protocolVersion) }
            try await unlock(id, dialect: status.dialect)
            _ = try await manager.command(deviceID: id, command(status.dialect), timeout: timeout)
            _ = try await readStatus(id: id); return success
        }
    }
    private func perform(deviceID: String, _ operation: @escaping () async throws -> String?) {
        guard !busy else { return }
        busy = true; clearDeviceMessage(deviceID)
        Task {
            do { setMessage(try await operation(), deviceID: deviceID) } catch { fail(error, deviceID: deviceID) }
            busy = false
        }
    }
    private func showPrompt(_ prompt: String, deviceID: String) {
        let messages = ["PROMPT TOUCH": "Touch the fingerprint sensor now.", "PROMPT LIFT": "Lift your finger.",
                        "PROMPT TOUCH_AGAIN": "Touch the sensor with the same finger again.",
                        "EVENT TOUCH": "Touch the fingerprint sensor now."]
        setMessage(messages[prompt] ?? prompt.replacingOccurrences(of: "PROMPT ", with: ""), deviceID: deviceID)
    }
    private func clearDeviceMessage(_ id: String) { setMessage(nil, deviceID: id) }
    private func setMessage(_ value: String?, deviceID: String) {
        guard let index = devices.firstIndex(where: { $0.id == deviceID }) else { return }
        devices[index].message = value; devices[index].isError = false
    }
    private func fail(_ error: Error, deviceID: String) {
        guard let index = devices.firstIndex(where: { $0.id == deviceID }) else { return }
        devices[index].message = error.localizedDescription; devices[index].isError = true
    }
    private func failSelected(_ error: Error) { if let id = selectedID { fail(error, deviceID: id) } }
    private func setAppMessage(_ value: String?) { appMessage = value; appMessageIsError = false }
    private func failApp(_ error: Error) { appMessage = error.localizedDescription; appMessageIsError = true }

    private func randomKeyOffMain() async throws -> Data {
        try await Task.detached {
            var data = Data(count: 32); let count = data.count
            let status = data.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, count, $0.baseAddress!) }
            guard status == errSecSuccess else { throw DeviceError.response("Could not create a secure pairing key (\(status)).") }
            return data
        }.value
    }
    private func pairingKey(_ id: String, background: Bool = false) async throws -> Data? {
        try await Task.detached { try KeychainStore.pairingKey(account: id, background: background) }.value
    }
    private func hasPassword(_ id: String, background: Bool = false) async throws -> Bool {
        try await Task.detached {
            try KeychainStore.get(service: KeychainStore.passwordService, account: id, background: background) != nil
        }.value
    }
    private func keyID(_ key: Data) async throws -> String { try await Task.detached { try HIDProtocol.keyID(key) }.value }
    private func saveCredentials(key: Data, password: String, id: String) async throws {
        try await Task.detached {
            try KeychainStore.set(Data(key.hex.utf8), service: KeychainStore.pairingService, account: id)
            try KeychainStore.set(Data(password.utf8), service: KeychainStore.passwordService, account: id)
        }.value
    }
    private static func legacyJobLoaded() -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = ["print", "gui/\(getuid())/com.tinytouch.helper"]
        process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return false }
        process.waitUntilExit(); return process.terminationStatus == 0
    }
}
