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

struct FingerprintPrompt: Equatable {
    let deviceID: String
    let message: String
}

struct FirmwareViewState: Equatable {
    enum Phase: Equatable { case idle, checking, ready, downloading, writing, reconnect, complete, failed }
    var phase: Phase = .idle
    var target = "no_device_selected"
    var current = "common_unknown"
    var latest = "common_unknown"
    var strategy: FirmwareStrategy?
    var progress = 0.0
    var message = "check_compatible_firmware_release"
    var error: String?
    var needsManualBoot = false
}

@MainActor
final class AppState: ObservableObject {
    static weak var active: AppState?
    @Published var devices: [DeviceViewState] = []
    @Published var selectedID: String?
    @Published var busy = false
    @Published var appMessage: String?
    @Published var appMessageIsError = false
    @Published private(set) var setup: DeviceSetupState?
    @Published private(set) var fingerprintPrompt: FingerprintPrompt?
    @Published private(set) var matchedFingerprint: Int?
    @Published private(set) var backgroundEnabled: Bool
    @Published private(set) var launchAtLogin: Bool
    @Published private(set) var legacyHelperDetected: Bool
    @Published private(set) var legacyOwners: [PortOwner] = []
    @Published private(set) var onboardingComplete: Bool
    @Published private(set) var keyboardMode = KeyboardMode.auto
    @Published private(set) var advancedFirmwareDevices = false
    @Published private(set) var firmware = FirmwareViewState()
    @Published private(set) var showFlashOnboarding = false
    @Published private(set) var language = AppLanguage.saved

    private let manager = DeviceManager(), defaults = UserDefaults.standard
    private var window: NSWindow?, windowCloseObserver: NSObjectProtocol?, knownOpened: Set<String> = []
    private var fingerprintsVisible = false, fingerprintFlashTask: Task<Void, Never>?
    private var setupPassword: String?, setupKey: Data?
    private var firmwareUpdate: FirmwareUpdate?, firmwareImageURL: URL?
    private var pendingFactoryVerification: (id: String, locationID: Int?)?
    private var pendingOTAVerification: (id: String, locationID: Int?, version: String)?
    private var flashOnboardingVisibility = FlashOnboardingVisibility()
    private var newBoardFlashActive = false
    private var newBoardFlashLocationID: Int?
    private var newBoardFactoryResetting = false
    private let legacyPlist = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/LaunchAgents/com.tinytouch.helper.plist")

    var selectedDevice: DeviceViewState? { devices.first { $0.id == selectedID } }
    var selectedMode: SetupMode? { selectedDevice?.status.flatMap { SetupMode(rawValue: $0.mode) } }
    var showsHIDServiceControls: Bool {
        devices.isEmpty || devices.contains { $0.status == nil || $0.status?.mode == SetupMode.hid.rawValue }
    }
    var summary: String {
        if let error = devices.first(where: { $0.connection == .error }) { return L10n.text("error_device", error.name) }
        let ready = devices.filter { $0.connection == .ready }.count
        if ready > 0 { return ready == 1 ? L10n.text("hid_ready") : L10n.text("hid_ready_devices", ready) }
        return L10n.text(devices.isEmpty ? "no_tinytouch_connected" : "tinytouch_connected")
    }
    var menuIcon: String {
        if devices.contains(where: { $0.connection == .error }) { return "exclamationmark.triangle.fill" }
        return devices.isEmpty ? "lock" : "lock.fill"
    }
    var isFirmwareWriting: Bool { firmware.phase == .writing }
    var canRetryNewBoardFactoryReset: Bool { newBoardFlashActive && firmware.phase == .failed && !firmware.needsManualBoot }

    init() {
        onboardingComplete = defaults.bool(forKey: "onboardingComplete")
        backgroundEnabled = defaults.object(forKey: "backgroundEnabled") as? Bool ?? true
        newBoardFlashLocationID = defaults.object(forKey: "newBoardFlashLocationID") as? Int
        launchAtLogin = SMAppService.mainApp.status == .enabled
        legacyHelperDetected = FileManager.default.fileExists(atPath: legacyPlist.path) || Self.legacyJobLoaded()
        Self.active = self
        if legacyHelperDetected { legacyOwners = LegacyProcessInspector.owners(ports: SerialDiscovery.devices().map(\.port)) }
        manager.onPrompt = { [weak self] id, prompt in self?.showPrompt(prompt, deviceID: id) }
        manager.onFingerprintMatch = { [weak self] id, slot in self?.flashFingerprint(slot, deviceID: id) }
        manager.onChange = { [weak self] identities, opened, ready, errors in
            self?.update(identities, opened: opened, ready: ready, errors: errors)
        }
        manager.start(enabled: backgroundEnabled && !legacyHelperDetected)
        if !onboardingComplete || devices.isEmpty || devices.contains(where: { $0.identity.kind != .runtime }) {
            DispatchQueue.main.async { [weak self] in self?.showWindow() }
        }
    }

    func showWindow() {
        // Let the MenuBarExtra menu dismiss before activating its window.
        DispatchQueue.main.async { [self] in
            NSApp.setActivationPolicy(.regular)
            if window == nil {
                let controller = NSHostingController(rootView: ContentView().environmentObject(self))
                let newWindow = NSWindow(contentViewController: controller)
                newWindow.title = "TinyTouch"; newWindow.setContentSize(NSSize(width: 800, height: 600))
                newWindow.contentMinSize = NSSize(width: 720, height: 600)
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
        guard !isFirmwareWriting else { return }
        backgroundEnabled = enabled; defaults.set(enabled, forKey: "backgroundEnabled")
        manager.setEnabled(enabled && !legacyHelperDetected)
        setAppMessage(enabled ? "hid_service_enabled" : "hid_service_paused_notice")
    }
    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            launchAtLogin = enabled; defaults.set(enabled, forKey: "launchAtLogin")
        } catch { failApp(error) }
    }
    func setAdvancedFirmwareDevices(_ enabled: Bool) {
        guard !isFirmwareWriting else { return }
        advancedFirmwareDevices = enabled; manager.setAdvancedDiscovery(enabled)
    }
    func setLanguage(_ language: AppLanguage) {
        defaults.set(language.rawValue, forKey: AppLanguage.preferenceKey)
        self.language = language
    }

    func setFingerprintsVisible(_ visible: Bool) {
        fingerprintsVisible = visible
        if !visible { fingerprintFlashTask?.cancel(); matchedFingerprint = nil }
    }

    private func flashFingerprint(_ slot: Int, deviceID: String) {
        guard fingerprintsVisible, selectedID == deviceID else { return }
        fingerprintFlashTask?.cancel(); matchedFingerprint = slot
        fingerprintFlashTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 650_000_000)
            guard !Task.isCancelled else { return }
            self?.matchedFingerprint = nil
        }
    }

    func checkFirmware() {
        guard !busy, let device = selectedDevice else { return }
        busy = true; firmwareUpdate = nil; firmwareImageURL = nil
        firmware = FirmwareViewState(phase: .checking, target: device.name,
            current: device.status?.firmwareVersion ?? "rom_mode", message: "checking_reviewed_firmware_channel")
        Task {
            defer { busy = false }
            do {
                let channelData = try await Self.download(FirmwareSupport.channelURL)
                let release = try FirmwareChannel.decode(channelData,
                    appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0")
                let manifestData = try await Self.download(release.manifest)
                let update = try FirmwareSupport.update(channelData: channelData, manifestData: manifestData,
                    manifestURL: release.manifest,
                    appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0",
                    identity: device.identity, status: device.status)
                firmwareUpdate = update
                firmware.phase = .ready; firmware.latest = update.version.description
                firmware.strategy = update.strategy; firmware.message = update.strategy == .ota
                    ? "ota_preserves_hosts_settings"
                    : "factory_flash_written_confirmation"
            } catch FirmwareError.noUpdate {
                firmware.phase = .complete; firmware.message = "tinytouch_has_compatible_firmware"
            } catch { firmware.phase = .failed; firmware.error = L10n.error(error); firmware.message = "firmware_check_failed" }
        }
    }

    func installFirmware() {
        guard !busy, let update = firmwareUpdate, let device = selectedDevice else { return }
        pendingOTAVerification = nil
        busy = true; firmware.phase = .downloading; firmware.progress = 0; firmware.error = nil
        firmware.message = "downloading_verifying_firmware"
        Task {
            do {
                let image = try await FirmwareSupport.verifiedDownload(update)
                guard selectedDevice?.id == device.id else { throw FirmwareError.invalid("selected_device_changed_flashing") }
                if update.strategy == .ota {
                    firmware.phase = .writing; firmware.message = "writing_inactive_ota_slot"
                    try await FirmwareSupport.ota(image: image, digest: update.asset.sha256,
                        command: { [manager, weak self] command, timeout in
                            defer { if command == "AUTH" { self?.clearFingerprintPrompt(deviceID: device.id) } }
                            return try await manager.command(deviceID: device.id, command, timeout: timeout)
                        }, progress: { [weak self] value in self?.firmware.progress = value })
                    pendingOTAVerification = (device.id, device.identity.locationID, update.version.description)
                    firmware.phase = .reconnect; firmware.progress = 1
                    firmware.message = "ota_staged_new_firmware"
                } else {
                    let url = FileManager.default.temporaryDirectory.appendingPathComponent("tinytouch-\(UUID().uuidString).bin")
                    try image.write(to: url, options: [.atomic]); firmwareImageURL = url
                    try await flashFactory(device: device, imageURL: url, manualBoot: false)
                }
            } catch {
                firmware.phase = .failed; firmware.error = L10n.error(error)
                if let value = error as? FirmwareError, case .manualReset = value { firmware.needsManualBoot = true }
                firmware.message = "firmware_installation_stopped_safely"
            }
            busy = false
        }
    }

    func flashNewBoard() {
        guard !busy, let device = selectedDevice, device.identity.kind == .rom else {
            firmware = FirmwareViewState(phase: .failed, message: "connect_esp32_mode_first", error: "no_board_mode_selected")
            return
        }
        busy = true; newBoardFlashActive = true; newBoardFactoryResetting = false; showFlashOnboarding = true
        firmwareUpdate = nil; firmwareImageURL = nil
        firmware = FirmwareViewState(phase: .checking, target: device.name, current: "rom_mode",
            message: "fetching_reviewed_firmware")
        Task {
            do {
                let channelData = try await Self.download(FirmwareSupport.channelURL)
                let release = try FirmwareChannel.decode(channelData,
                    appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0")
                let manifestData = try await Self.download(release.manifest)
                let update = try FirmwareSupport.update(channelData: channelData, manifestData: manifestData,
                    manifestURL: release.manifest,
                    appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0",
                    identity: device.identity, status: nil)
                firmwareUpdate = update; firmware.latest = update.version.description; firmware.strategy = update.strategy
                firmware.phase = .downloading; firmware.message = "downloading_verifying_firmware"
                let image = try await FirmwareSupport.verifiedDownload(update)
                guard selectedDevice?.id == device.id else { throw FirmwareError.invalid("selected_board_changed_flashing") }
                let url = FileManager.default.temporaryDirectory.appendingPathComponent("tinytouch-\(UUID().uuidString).bin")
                try image.write(to: url, options: [.atomic]); firmwareImageURL = url
                try await flashFactory(device: device, imageURL: url, manualBoot: false)
            } catch {
                firmware.phase = .failed; firmware.error = L10n.error(error)
                if let value = error as? FirmwareError, case .manualReset = value { firmware.needsManualBoot = true }
                firmware.message = "flash_stopped_safely"
            }
            busy = false
        }
    }

    func retryManualFactoryFlash() {
        guard !busy, firmware.needsManualBoot, let imageURL = firmwareImageURL, let device = selectedDevice else { return }
        busy = true; firmware.error = nil; firmware.needsManualBoot = false
        Task {
            do { try await flashFactory(device: device, imageURL: imageURL, manualBoot: true) }
            catch { firmware.phase = .failed; firmware.error = L10n.error(error); firmware.message = "factory_flash_failed" }
            busy = false
        }
    }

    func retryNewBoardFactoryReset() {
        guard !busy, canRetryNewBoardFactoryReset, let id = selectedID else { return }
        busy = true; firmware.error = nil; firmware.message = "checking_tinytouch_factory_reset"
        Task {
            do {
                manager.reconnect(id)
                let status = try await waitForStatus(id: id)
                busy = false; resetNewBoard(id: id, status: status)
            } catch {
                firmware.phase = .failed; firmware.error = L10n.error(error)
                firmware.message = "factory_reset_stopped_safely"; busy = false
            }
        }
    }

    private func flashFactory(device: DeviceViewState, imageURL: URL, manualBoot: Bool) async throws {
        guard let identity = manager.acquireExclusive(device.id) else { throw DeviceError.disconnected }
        defer { manager.releaseExclusive(device.id) }
        let newBoardFlash = newBoardFlashActive
        firmware.phase = .writing; firmware.message = manualBoot ? "connecting_manually_rom_bootloader" : "entering_bootloader_factory_image"
        try await FirmwareFlasher.flash(port: identity.port, imageURL: imageURL, manualBoot: manualBoot) { [weak self] value in
            self?.firmware.progress = value
        }
        try? FileManager.default.removeItem(at: imageURL); firmwareImageURL = nil
        if newBoardFlash, let locationID = identity.locationID {
            newBoardFlashLocationID = locationID; defaults.set(locationID, forKey: "newBoardFlashLocationID")
        }
        if !newBoardFlash { pendingFactoryVerification = (device.id, identity.locationID) }
        firmware.phase = .reconnect; firmware.progress = 1
        firmware.message = newBoardFlash
            ? "firmware_installed_continue_setup"
            : "factory_image_default_verification"
    }

    private static func download(_ url: URL) async throws -> Data {
        let (data, response) = try await URLSession.shared.data(from: url)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw FirmwareError.invalid("firmware_server_returned_error") }
        return data
    }
    func completeOnboarding(launchAtLogin: Bool, replaceLegacy: Bool) {
        if replaceLegacy && legacyHelperDetected { replaceLegacyHelper() }
        setLaunchAtLogin(launchAtLogin); onboardingComplete = true; defaults.set(true, forKey: "onboardingComplete")
    }

    func startSetup(mode: SetupMode, password: String = "", confirmation: String = "") {
        guard !busy, var state = setup, state.phase == .chooseMode || state.error != nil else { return }
        do {
            if mode == .hid { try SetupValidation.password(password, confirmation: confirmation, mode: keyboardMode) }
        } catch { state.error = L10n.error(error); setup = state; return }
        state.mode = mode; state.phase = .authenticate; state.message = "authorizing_device_setup"
        state.error = nil; state.canSkipPairing = false; setup = state
        if mode == .hid { setupPassword = password }
        runSetup()
    }

    func retrySetup() {
        guard !busy, let state = setup, state.error != nil else { return }
        if state.mode == .piv && state.provisioningComplete { pairPIV() } else { runSetup() }
    }

    func startOverSetup() {
        guard !busy, var state = setup else { return }
        state.mode = nil; state.phase = .chooseMode; state.message = "choose_how_use_tinytouch"
        state.error = nil; state.provisioningComplete = false; state.canSkipPairing = false; state.pairingStarted = false
        setupPassword = nil; setupKey = nil; setup = state
    }

    func skipPIVPairing() {
        guard var state = setup, state.mode == .piv, state.provisioningComplete, state.canSkipPairing else { return }
        state.phase = .complete; state.message = "piv_ready_pairing_skipped"
        state.error = nil; state.canSkipPairing = false; setup = state
    }

    func finishSetup() {
        guard setup?.phase == .complete else { return }
        setup = nil; setupPassword = nil; setupKey = nil
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
        perform(deviceID: id) { [self] in try await readStatus(id: id); return "status_updated" }
    }

    func setHIDSettings(typingDelayMS: Int, submitEnter: Bool, touchCooldownMS: Int) {
        guard let id = selectedID else { return }
        perform(deviceID: id) { [self] in
            guard (1...100).contains(typingDelayMS), (100...5000).contains(touchCooldownMS) else {
                throw DeviceError.response("hid_settings_supported_range")
            }
            let current = try await status(id: id)
            guard current.protocolVersion == 6, current.mode == "hid",
                  current.typingDelayMS != nil, current.submitEnter != nil, current.touchCooldownMS != nil else {
                throw DeviceError.response("update_device_supports_hid_settings")
            }
            try await unlock(id, dialect: current.dialect)
            for command in [
                "SET TYPE_DELAY \(typingDelayMS)",
                "SET SUBMIT_ENTER \(submitEnter ? 1 : 0)",
                "SET COOLDOWN \(touchCooldownMS)",
            ] { _ = try await manager.command(deviceID: id, command) }
            let updated = try await readStatus(id: id)
            guard updated.typingDelayMS == typingDelayMS, updated.submitEnter == submitEnter,
                  updated.touchCooldownMS == touchCooldownMS else {
                throw DeviceError.response("device_not_hid_settings")
            }
            return "hid_settings_saved"
        }
    }

    func setIdleLED(_ enabled: Bool) {
        guard let id = selectedID else { return }
        perform(deviceID: id) { [self] in
            let current = try await status(id: id)
            guard current.protocolVersion == 6, current.idleLEDOn != nil else {
                throw DeviceError.response("update_device_led_setting")
            }
            try await unlock(id, dialect: current.dialect)
            _ = try await manager.command(deviceID: id, "SET LED_IDLE \(enabled ? 1 : 0)")
            let updated = try await readStatus(id: id)
            guard updated.idleLEDOn == enabled else {
                throw DeviceError.response("device_not_led_setting")
            }
            return "idle_led_setting_saved"
        }
    }

    func changeMode(to mode: SetupMode) {
        guard let id = selectedID, let device = selectedDevice else { return }
        perform(deviceID: id) { [self] in
            let current = try await status(id: id)
            guard current.protocolVersion == 6 else {
                throw DeviceError.response("mode_changes_6_firmware")
            }
            guard current.sensorReady else { throw DeviceError.response("fingerprint_sensor_not_responding") }
            guard current.mode != mode.rawValue else { return L10n.text("tinytouch_mode", mode.rawValue.uppercased()) }

            var provisioned = current.isProvisioned(mode: mode)
            if provisioned && mode == .hid {
                let hosts = try await hostList(id, dialect: current.dialect)
                let key = try await pairingKey(id)
                let hasLocalPassword = try await hasPassword(id)
                provisioned = try key.map { hosts.ids.contains(try HIDProtocol.keyID($0)) } == true && hasLocalPassword
            }
            if !provisioned {
                setup = DeviceSetupState(deviceID: id, deviceName: device.name, mode: mode,
                                         message: L10n.text("complete_setup_switch_modes", mode.rawValue.uppercased()))
                return nil
            }

            try await unlock(id, dialect: current.dialect)
            guard let command = current.dialect.setMode(mode) else {
                throw DeviceError.response("mode_changes_6_firmware")
            }
            _ = try await manager.command(deviceID: id, command)
            _ = try await waitForStatus(id: id, mode: mode)
            _ = try await readStatus(id: id)
            if mode == .hid { manager.markReady(id) }
            return L10n.text("switched_tinytouch_data_preserved", mode.rawValue.uppercased())
        }
    }

    func configureHID(password: String, confirmation: String, enroll: Bool) {
        guard !password.isEmpty else { failSelected(DeviceError.response("password_cannot_empty")); return }
        guard password == confirmation else { failSelected(DeviceError.response("passwords_not_match")); return }
        guard let id = selectedID else { return }
        perform(deviceID: id) { [self] in
            var status = try await status(id: id)
            guard status.isCompatible else { throw DeviceError.unsupportedProtocol(status.protocolVersion) }
            guard status.mode == "hid" else { throw DeviceError.response("switch_tinytouch_try_again") }
            guard status.sensorReady else { throw DeviceError.response("fingerprint_sensor_not_responding") }
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
                        throw DeviceError.response("device_trusts_hid_computers")
                    }
                    _ = try await manager.command(deviceID: id, status.dialect.hostAdd(id: keyID, key: key.hex))
                }
            } else {
                if status.hidKeyConfigured && existingKey == nil {
                    throw DeviceError.response("legacy_single_adding_mac")
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
            return "hid_ready_device_confirmation"
        }
    }

    func enroll(slot: Int) { mutateFingerprint({ $0.enroll(slot: slot) }, success: L10n.text("fingerprint_enrolled_slot", slot), timeout: 50) }
    func deleteFingerprint(slot: Int) { mutateFingerprint({ $0.delete(slot: slot) }, success: L10n.text("fingerprint_slot_deleted", slot)) }
    func deleteAllFingerprints() { mutateFingerprint({ $0.clear }, success: "fingerprints_deleted") }
    func factoryReset() {
        guard !busy, let id = selectedID else { return }
        busy = true; setAppMessage(nil)
        Task {
            defer { clearFingerprintPrompt(deviceID: id); busy = false }
            do {
                let current = try await self.status(id: id)
                guard let command = current.dialect.factoryReset else {
                    throw DeviceError.response("factory_reset_6_firmware")
                }
                guard current.sensorReady else {
                    throw DeviceError.response("fingerprint_sensor_erase_templates")
                }
                try await unlock(id, dialect: current.dialect)
                _ = try await manager.command(deviceID: id, command, timeout: 15)
                do {
                    guard try await status(id: id).isFactoryDefault else {
                        throw DeviceError.response("factory_reset_data_preserved")
                    }
                    try await deleteLocalData(id)
                } catch {
                    manager.reconnect(id); throw error
                }
                manager.reconnect(id)
                setAppMessage("factory_reset_credentials_erased")
            } catch { failApp(error) }
        }
    }
    func refreshComputers() {
        guard let id = selectedID else { return }
        perform(deviceID: id) { [self] in try await readComputers(id: id); return "computer_list_updated" }
    }
    func addCurrentMac() {
        guard let id = selectedID else { return }
        perform(deviceID: id) { [self] in
            guard let key = try await pairingKey(id), try await hasPassword(id) else { throw DeviceError.missingCredentials }
            let status = try await status(id: id)
            guard status.isCompatible, status.protocolVersion >= 2 else {
                throw DeviceError.response("firmware_supports_hid_computer")
            }
            try await unlock(id, dialect: status.dialect)
            let hosts = try await hostList(id, dialect: status.dialect), keyID = try await keyID(key)
            if !hosts.ids.contains(keyID) {
                guard hosts.capacity == 0 || hosts.ids.count < hosts.capacity else { throw DeviceError.response("hid_list_full_error") }
                _ = try await manager.command(deviceID: id, status.dialect.hostAdd(id: keyID, key: key.hex))
            }
            try await readComputers(id: id); return "mac_trusted_hid"
        }
    }
    func removeComputer(id hostID: String) {
        guard let deviceID = selectedID, Data(strictHex: hostID, count: 8) != nil else { return }
        perform(deviceID: deviceID) { [self] in
            let status = try await status(id: deviceID)
            try await unlock(deviceID, dialect: status.dialect)
            _ = try await manager.command(deviceID: deviceID, status.dialect.hostRemove(id: hostID.lowercased()))
            try await readComputers(id: deviceID); return "computer_removed"
        }
    }

    func setKeyboardMode(_ mode: KeyboardMode) {
        guard !isFirmwareWriting, let id = selectedID else { return }
        do {
            try KeyboardSettingsStore().save(KeyboardSettings(keyboardLayout: mode), deviceID: id)
            keyboardMode = mode; setAppMessage(L10n.text("keyboard_layout_saved", id))
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
            setAppMessage("diagnostics_exported")
        } catch { failApp(error) }
    }

    func replaceLegacyHelper() {
        guard !busy else { return }
        busy = true; manager.setEnabled(false); setAppMessage("waiting_legacy_release_tinytouch")
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
                    setAppMessage("legacy_helper_state_preserved")
                } catch { failApp(error) }
            } else {
                legacyHelperDetected = true
                failApp(DeviceError.response(L10n.text("serial_port_replace_again", remaining.map(\.detail).joined(separator: "; "))))
            }
            busy = false
        }
    }

    private func update(_ identities: [DeviceIdentity], opened: Set<String>, ready: Set<String>, errors: [String: Error]) {
        flashOnboardingVisibility.update(hasROM: identities.contains { $0.kind == .rom })
        showFlashOnboarding = setup == nil && (flashOnboardingVisibility.visible || newBoardFlashActive)
        let previous = Dictionary(uniqueKeysWithValues: devices.map { ($0.id, $0) })
        let retainedROM = showFlashOnboarding && !identities.contains { $0.kind == .rom }
            ? previous[selectedID ?? ""].flatMap { $0.identity.kind == .rom ? $0 : nil }
                ?? previous.values.first(where: { $0.identity.kind == .rom }) : nil
        let newlyOpened = opened.subtracting(knownOpened); knownOpened = opened
        devices = identities.map { identity in
            var device = previous[identity.id] ?? DeviceViewState(identity: identity, connection: .connected)
            device.identity = identity
            device.connection = errors[identity.id] != nil || device.status?.isCompatible == false
                ? .error : (ready.contains(identity.id) ? .ready : .connected)
            if let error = errors[identity.id] { device.message = L10n.error(error); device.isError = true }
            else if newlyOpened.contains(identity.id), device.connection != .error { device.message = nil; device.isError = false }
            return device
        }
        if let retainedROM, retainedROM.identity.kind == .rom { devices.append(retainedROM) }
        if let pending = pendingFactoryVerification,
           let runtime = identities.first(where: { $0.kind == .runtime &&
               (pending.locationID == nil ? $0.id == pending.id : $0.locationID == pending.locationID) }),
           opened.contains(runtime.id) {
            pendingFactoryVerification = nil
            Task {
                do {
                    let current = try await status(id: runtime.id)
                    guard current.isFactoryDefault else { throw FirmwareError.invalid("flashed_device_credentials_preserved") }
                    try await deleteLocalData(pending.id)
                    firmware.phase = .complete; firmware.message = "factory_flash_credentials_reset"
                } catch { firmware.phase = .failed; firmware.error = L10n.error(error); firmware.message = "post_flash_verification_failed" }
            }
        }
        if let pending = pendingOTAVerification,
           let runtime = identities.first(where: { $0.kind == .runtime &&
               (pending.locationID == nil ? $0.id == pending.id : $0.locationID == pending.locationID) }),
           opened.contains(runtime.id) {
            pendingOTAVerification = nil
            Task {
                do {
                    let current = try await status(id: runtime.id)
                    guard current.firmwareVersion == pending.version else {
                        throw FirmwareError.invalid(L10n.text("device_restarted_firmware_expected", current.firmwareVersion, pending.version))
                    }
                    firmware.phase = .complete; firmware.current = current.firmwareVersion
                    firmware.message = "firmware_update_verified"
                } catch { firmware.phase = .failed; firmware.error = L10n.error(error); firmware.message = "post_update_verification_failed" }
            }
        }
        if let rom = identities.first(where: { $0.kind == .rom }) { selectedID = rom.id }
        else if let retainedROM, retainedROM.identity.kind == .rom { selectedID = retainedROM.id }
        else if let setup { selectedID = setup.deviceID }
        else if selectedID == nil || !identities.contains(where: { $0.id == selectedID }) { selectedID = identities.first?.id }
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
        beginSetupIfNeeded(value, id: id)
        return value
    }

    private func beginSetupIfNeeded(_ status: DeviceStatus, id: String) {
        guard setup == nil, let device = devices.first(where: { $0.id == id }) else { return }
        if let locationID = newBoardFlashLocationID, locationID == device.identity.locationID { newBoardFlashActive = true }
        if newBoardFlashActive {
            resetNewBoard(id: id, status: status)
            return
        }
        guard status.isFactoryDefault else { return }
        selectedID = id; keyboardMode = KeyboardSettingsStore().load(deviceID: id).keyboardLayout
        newBoardFlashActive = false; showFlashOnboarding = false
        setup = DeviceSetupState(deviceID: id, deviceName: device.name)
        showWindow()
    }

    private func resetNewBoard(id: String, status: DeviceStatus) {
        guard !newBoardFactoryResetting else { return }
        newBoardFactoryResetting = true; busy = true
        firmware.message = "resetting_tinytouch_factory_defaults"
        Task {
            defer { newBoardFactoryResetting = false; busy = false }
            do {
                guard let command = status.dialect.factoryReset else {
                    throw DeviceError.response("factory_reset_6_firmware")
                }
                guard status.sensorReady else {
                    throw DeviceError.response("fingerprint_sensor_reset_tinytouch")
                }
                try await unlock(id, dialect: status.dialect)
                _ = try await manager.command(deviceID: id, command, timeout: 15)
                let current = try await self.status(id: id)
                guard current.isFactoryDefault else {
                    throw DeviceError.response("factory_reset_verification_failed")
                }
                newBoardFlashActive = false; newBoardFlashLocationID = nil; defaults.removeObject(forKey: "newBoardFlashLocationID"); showFlashOnboarding = false
                beginSetupIfNeeded(current, id: id)
            } catch {
                firmware.phase = .failed; firmware.error = L10n.error(error)
                firmware.message = "factory_reset_stopped_safely"
            }
        }
    }

    private func runSetup() {
        guard !busy, let state = setup, let mode = state.mode else { return }
        busy = true; updateSetup(.authenticate, "authorizing_device_setup")
        Task {
            do {
                let id = state.deviceID
                var current = try await status(id: id)
                guard current.protocolVersion == 6 else { throw DeviceError.response("setup_requires_6_firmware") }
                guard current.sensorReady else { throw DeviceError.response("fingerprint_sensor_not_responding") }
                try await unlock(id, dialect: current.dialect)
                if mode == .hid {
                    updateSetup(.registerMac, "registering_mac_securely")
                    let storedKey = try await pairingKey(id)
                    let key: Data
                    if let setupKey { key = setupKey }
                    else if let storedKey { key = storedKey }
                    else { key = try await randomKeyOffMain() }
                    setupKey = key
                    let hosts = try await hostList(id, dialect: current.dialect), hostID = try await keyID(key)
                    if !hosts.ids.contains(hostID) {
                        guard hosts.capacity == 0 || hosts.ids.count < hosts.capacity else {
                            throw DeviceError.response("device_trusts_hid_computers")
                        }
                        _ = try await manager.command(deviceID: id, current.dialect.hostAdd(id: hostID, key: key.hex))
                    }
                    if let password = setupPassword {
                        try await saveCredentials(key: key, password: password, id: id); setupPassword = nil
                    } else if !(try await hasPassword(id)) {
                        throw DeviceError.response("enter_password_resume_setup")
                    }
                }
                if current.mode != mode.rawValue {
                    updateSetup(.switchMode, L10n.text("switching_tinytouch_mode", mode.rawValue.uppercased()))
                    guard let command = current.dialect.setMode(mode) else { throw DeviceError.response("mode_changes_6_firmware") }
                    _ = try await manager.command(deviceID: id, command)
                    current = try await waitForStatus(id: id, mode: mode)
                }
                try await unlock(id, dialect: current.dialect)
                if mode == .piv && current.fields["piv"] != "ready" {
                    updateSetup(.createIdentity, "creating_piv_identity")
                    guard let command = current.dialect.pivCreate else { throw DeviceError.response("piv_setup_6_firmware") }
                    _ = try await manager.command(deviceID: id, command, timeout: 90)
                    current = try await status(id: id)
                    guard current.fields["piv"] == "ready" else { throw DeviceError.response("piv_identity_not_created") }
                }
                if current.fingerprintCount == 0 {
                    updateSetup(.enroll, "touch_sensor_enroll_fingerprint")
                    showPrompt("PROMPT TOUCH", deviceID: id)
                    defer { clearFingerprintPrompt(deviceID: id) }
                    _ = try await manager.command(deviceID: id, current.dialect.enroll(slot: 1), timeout: 50)
                }
                updateSetup(.verify, "verifying_setup")
                current = try await readStatus(id: id)
                guard current.isSetupComplete(mode: mode) else { throw DeviceError.response(L10n.text("setup_verification_ready_configuration", mode.rawValue.uppercased())) }
                if mode == .hid {
                    guard let key = try await pairingKey(id), try await hasPassword(id) else { throw DeviceError.missingCredentials }
                    let hosts = try await hostList(id, dialect: current.dialect)
                    guard hosts.ids.contains(try await keyID(key)) else { throw DeviceError.response("mac_not_host_list") }
                    manager.markReady(id); completeSetup("hid_ready_fingerprint")
                } else {
                    if var setup {
                        setup.phase = .pair; setup.provisioningComplete = true; setup.canSkipPairing = true
                        setup.message = "unplug_tinytouch_pair_macos"
                        self.setup = setup
                    }
                    busy = false; return
                }
            } catch { failSetup(error) }
            busy = false
        }
    }

    private func waitForStatus(id: String, mode: SetupMode? = nil) async throws -> DeviceStatus {
        let deadline = Date().addingTimeInterval(8); var reconnected = false
        while Date() < deadline {
            do {
                let current = try await status(id: id)
                if mode == nil || current.mode == mode?.rawValue { return current }
            } catch {
                if !reconnected { manager.reconnect(id); reconnected = true }
            }
            try await Task.sleep(nanoseconds: 250_000_000)
        }
        throw DeviceError.response(mode.map { L10n.text("tinytouch_not_reconnect_mode", $0.rawValue.uppercased()) } ?? L10n.text("tinytouch_not_reconnect"))
    }

    func pairPIV() {
        guard !busy, setup?.mode == .piv else { return }
        busy = true; updateSetup(.pair, "opening_macos_piv_pairing")
        Task {
            let failure = await Task.detached { Self.runPIVPairing() }.value
            if let failure, var state = setup { state.recordPairingFailure(failure); setup = state }
            else if var state = setup {
                state.pairingStarted = true
                state.message = "macos_asks_pin_manually"
                setup = state
            }
            busy = false
        }
    }

    nonisolated private static func runPIVPairing() -> String? {
        func run(_ arguments: [String]) -> (Int32, String, String) {
            let process = Process(), output = Pipe(), error = Pipe()
            process.executableURL = URL(fileURLWithPath: "/usr/sbin/sc_auth"); process.arguments = arguments
            process.standardOutput = output; process.standardError = error
            do { try process.run(); process.waitUntilExit() }
            catch { return (-1, "", L10n.error(error)) }
            return (process.terminationStatus,
                    String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self),
                    String(decoding: error.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
        }
        let deadline = Date().addingTimeInterval(10)
        var failure = "macos_not_choose_retry"
        while Date() < deadline {
            let identities = run(["identities"])
            if let result = SCAuthResult.identities(exitCode: identities.0, output: identities.1, error: identities.2) {
                if !identities.2.isEmpty { return result }
                failure = result; Thread.sleep(forTimeInterval: 0.5); continue
            }
            let pairing = run(["pairing_ui", "-f"])
            return SCAuthResult.pairingLaunch(exitCode: pairing.0, error: pairing.2)
        }
        return failure
    }

    func confirmPIVPairing() {
        guard !busy, setup?.mode == .piv, setup?.pairingStarted == true else { return }
        completeSetup("piv_ready_paired_macos")
    }

    private func updateSetup(_ phase: DeviceSetupPhase, _ message: String) {
        guard var state = setup else { return }
        state.phase = phase; state.message = message; state.error = nil; setup = state
    }
    private func completeSetup(_ message: String) {
        updateSetup(.complete, message); setupPassword = nil; setupKey = nil
    }
    private func failSetup(_ error: Error) {
        guard var state = setup else { return }
        state.error = L10n.error(error); setup = state
    }
    private func status(id: String) async throws -> DeviceStatus {
        let lines = try await manager.command(deviceID: id, "STATUS")
        guard let line = lines.last(where: { $0.hasPrefix("OK STATUS ") }) else { throw DeviceError.response("no_status_response_received") }
        let status = try DeviceStatus(line: line)
        guard status.fields["product_id"] == DeviceStatus.productID else { throw DeviceError.foreignFirmware }
        return status
    }
    private func hostList(_ id: String, dialect: DeviceDialect? = nil) async throws -> HIDHostList {
        let deviceStatus = dialect == nil ? try await status(id: id) : nil
        let resolved = dialect ?? deviceStatus!.dialect
        guard resolved != .unsupported else { throw DeviceError.unsupportedProtocol(deviceStatus?.protocolVersion ?? 0) }
        let lines = try await manager.command(deviceID: id, resolved.hostList)
        guard let line = lines.last(where: { $0.hasPrefix("OK HID_KEY_IDS ") || $0.hasPrefix("OK HOST LIST ") })
        else { throw DeviceError.response("no_computer_list_received") }
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
        defer { clearFingerprintPrompt(deviceID: id) }
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
            defer { clearFingerprintPrompt(deviceID: deviceID); busy = false }
            do { setMessage(try await operation(), deviceID: deviceID) } catch { fail(error, deviceID: deviceID) }
        }
    }
    private func showPrompt(_ prompt: String, deviceID: String) {
        let messages = ["PROMPT TOUCH": "touch_fingerprint_sensor_now", "PROMPT LIFT": "lift_finger",
                        "PROMPT TOUCH_AGAIN": "touch_sensor_finger_again",
                        "EVENT TOUCH": "touch_fingerprint_sensor_now"]
        let message = messages[prompt] ?? prompt.replacingOccurrences(of: "PROMPT ", with: "")
        fingerprintPrompt = FingerprintPrompt(deviceID: deviceID, message: message)
        setMessage(message, deviceID: deviceID)
    }
    private func clearFingerprintPrompt(deviceID: String) {
        if fingerprintPrompt?.deviceID == deviceID { fingerprintPrompt = nil }
    }
    private func clearDeviceMessage(_ id: String) { setMessage(nil, deviceID: id) }
    private func setMessage(_ value: String?, deviceID: String) {
        guard let index = devices.firstIndex(where: { $0.id == deviceID }) else { return }
        devices[index].message = value; devices[index].isError = false
    }
    private func fail(_ error: Error, deviceID: String) {
        guard let index = devices.firstIndex(where: { $0.id == deviceID }) else { return }
        devices[index].message = L10n.error(error); devices[index].isError = true
    }
    private func failSelected(_ error: Error) { if let id = selectedID { fail(error, deviceID: id) } }
    private func setAppMessage(_ value: String?) { appMessage = value; appMessageIsError = false }
    private func failApp(_ error: Error) { appMessage = L10n.error(error); appMessageIsError = true }

    private func randomKeyOffMain() async throws -> Data {
        try await Task.detached {
            var data = Data(count: 32); let count = data.count
            let status = data.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, count, $0.baseAddress!) }
            guard status == errSecSuccess else { throw DeviceError.response(L10n.text("not_create_pairing_key", status)) }
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
    private func deleteLocalData(_ id: String) async throws {
        try await Task.detached {
            var firstError: Error?
            func attempt(_ operation: () throws -> Void) {
                do { try operation() } catch { if firstError == nil { firstError = error } }
            }
            attempt { try KeychainStore.delete(service: KeychainStore.pairingService, account: id) }
            for account in [id] + (1...5).map({ "\(id):fingerprint:\($0)" }) {
                attempt { try KeychainStore.delete(service: KeychainStore.passwordService, account: account) }
            }
            attempt { try ReplayStateStore().remove(deviceID: id) }
            attempt { try KeyboardSettingsStore().remove(deviceID: id) }
            if let firstError {
                throw DeviceError.response(L10n.text("device_reset_not_erased", firstError.localizedDescription))
            }
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
