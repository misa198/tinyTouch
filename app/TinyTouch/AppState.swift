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
    var target = "No device selected"
    var current = "Unknown"
    var latest = "Unknown"
    var strategy: FirmwareStrategy?
    var progress = 0.0
    var message = "Check for a compatible firmware release."
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
    @Published private(set) var backgroundEnabled: Bool
    @Published private(set) var launchAtLogin: Bool
    @Published private(set) var legacyHelperDetected: Bool
    @Published private(set) var legacyOwners: [PortOwner] = []
    @Published private(set) var onboardingComplete: Bool
    @Published private(set) var keyboardMode = KeyboardMode.auto
    @Published private(set) var advancedFirmwareDevices = false
    @Published private(set) var firmware = FirmwareViewState()
    @Published private(set) var showFlashOnboarding = false

    private let manager = DeviceManager(), defaults = UserDefaults.standard
    private var window: NSWindow?, windowCloseObserver: NSObjectProtocol?, knownOpened: Set<String> = []
    private var setupPassword: String?, setupKey: Data?
    private var firmwareUpdate: FirmwareUpdate?, firmwareImageURL: URL?
    private var pendingFactoryVerification: (id: String, locationID: Int?)?
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
        if let error = devices.first(where: { $0.connection == .error }) { return "Error — \(error.name)" }
        let ready = devices.filter { $0.connection == .ready }.count
        if ready > 0 { return ready == 1 ? "HID ready" : "HID ready on \(ready) devices" }
        return devices.isEmpty ? "No tinyTouch connected" : "tinyTouch connected"
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
        setAppMessage(enabled ? "HID service enabled." : "HID service paused.")
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

    func checkFirmware() {
        guard !busy, let device = selectedDevice else { return }
        busy = true; firmwareUpdate = nil; firmwareImageURL = nil
        firmware = FirmwareViewState(phase: .checking, target: device.name,
            current: device.status?.firmwareVersion ?? "ROM mode", message: "Checking the reviewed firmware channel…")
        Task {
            defer { busy = false }
            do {
                let channelData = try await Self.download(FirmwareSupport.channelURL)
                let release = try FirmwareChannel.decode(channelData,
                    appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0")
                let manifestData = try await Self.download(release.manifest)
                let update = try FirmwareSupport.update(channelData: channelData, manifestData: manifestData,
                    manifestURL: release.manifest,
                    appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0",
                    identity: device.identity, status: device.status)
                firmwareUpdate = update
                firmware.phase = .ready; firmware.latest = update.version.description
                firmware.strategy = update.strategy; firmware.message = update.strategy == .ota
                    ? "OTA preserves fingerprints, keys, hosts, and settings."
                    : "Factory flash resets all device data. The image is written only after confirmation."
            } catch { firmware.phase = .failed; firmware.error = error.localizedDescription; firmware.message = "Firmware check failed." }
        }
    }

    func installFirmware() {
        guard !busy, let update = firmwareUpdate, let device = selectedDevice else { return }
        busy = true; firmware.phase = .downloading; firmware.progress = 0; firmware.error = nil
        firmware.message = "Downloading and verifying firmware…"
        Task {
            do {
                let image = try await FirmwareSupport.verifiedDownload(update)
                guard selectedDevice?.id == device.id else { throw FirmwareError.invalid("Selected device changed before flashing.") }
                if update.strategy == .ota {
                    firmware.phase = .writing; firmware.message = "Writing the inactive OTA slot…"
                    try await FirmwareSupport.ota(image: image, digest: update.asset.sha256,
                        command: { [manager] command, timeout in
                            try await manager.command(deviceID: device.id, command, timeout: timeout)
                        }, progress: { [weak self] value in self?.firmware.progress = value })
                    firmware.phase = .reconnect; firmware.progress = 1
                    firmware.message = "OTA is staged. Unplug tinyTouch and reconnect it to boot the new firmware."
                } else {
                    let url = FileManager.default.temporaryDirectory.appendingPathComponent("tinytouch-\(UUID().uuidString).bin")
                    try image.write(to: url, options: [.atomic]); firmwareImageURL = url
                    try await flashFactory(device: device, imageURL: url, manualBoot: false)
                }
            } catch {
                firmware.phase = .failed; firmware.error = error.localizedDescription
                if let value = error as? FirmwareError, case .manualReset = value { firmware.needsManualBoot = true }
                firmware.message = "Firmware installation stopped safely."
            }
            busy = false
        }
    }

    func flashNewBoard() {
        guard !busy, let device = selectedDevice, device.identity.kind == .rom else {
            firmware = FirmwareViewState(phase: .failed, message: "Connect an ESP32-S3 in download mode first.", error: "No board in download mode is selected.")
            return
        }
        busy = true; newBoardFlashActive = true; newBoardFactoryResetting = false; showFlashOnboarding = true
        firmwareUpdate = nil; firmwareImageURL = nil
        firmware = FirmwareViewState(phase: .checking, target: device.name, current: "ROM mode",
            message: "Fetching the reviewed firmware…")
        Task {
            do {
                let channelData = try await Self.download(FirmwareSupport.channelURL)
                let release = try FirmwareChannel.decode(channelData,
                    appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0")
                let manifestData = try await Self.download(release.manifest)
                let update = try FirmwareSupport.update(channelData: channelData, manifestData: manifestData,
                    manifestURL: release.manifest,
                    appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0",
                    identity: device.identity, status: nil)
                firmwareUpdate = update; firmware.latest = update.version.description; firmware.strategy = update.strategy
                firmware.phase = .downloading; firmware.message = "Downloading and verifying firmware…"
                let image = try await FirmwareSupport.verifiedDownload(update)
                guard selectedDevice?.id == device.id else { throw FirmwareError.invalid("Selected board changed before flashing.") }
                let url = FileManager.default.temporaryDirectory.appendingPathComponent("tinytouch-\(UUID().uuidString).bin")
                try image.write(to: url, options: [.atomic]); firmwareImageURL = url
                try await flashFactory(device: device, imageURL: url, manualBoot: false)
            } catch {
                firmware.phase = .failed; firmware.error = error.localizedDescription
                if let value = error as? FirmwareError, case .manualReset = value { firmware.needsManualBoot = true }
                firmware.message = "Flash stopped safely."
            }
            busy = false
        }
    }

    func retryManualFactoryFlash() {
        guard !busy, firmware.needsManualBoot, let imageURL = firmwareImageURL, let device = selectedDevice else { return }
        busy = true; firmware.error = nil; firmware.needsManualBoot = false
        Task {
            do { try await flashFactory(device: device, imageURL: imageURL, manualBoot: true) }
            catch { firmware.phase = .failed; firmware.error = error.localizedDescription; firmware.message = "Factory flash failed." }
            busy = false
        }
    }

    func retryNewBoardFactoryReset() {
        guard !busy, canRetryNewBoardFactoryReset, let id = selectedID else { return }
        busy = true; firmware.error = nil; firmware.message = "Checking tinyTouch before retrying factory reset…"
        Task {
            do {
                manager.reconnect(id)
                let status = try await waitForStatus(id: id)
                busy = false; resetNewBoard(id: id, status: status)
            } catch {
                firmware.phase = .failed; firmware.error = error.localizedDescription
                firmware.message = "Factory reset stopped safely."; busy = false
            }
        }
    }

    private func flashFactory(device: DeviceViewState, imageURL: URL, manualBoot: Bool) async throws {
        guard let identity = manager.acquireExclusive(device.id) else { throw DeviceError.disconnected }
        defer { manager.releaseExclusive(device.id) }
        let newBoardFlash = newBoardFlashActive
        firmware.phase = .writing; firmware.message = manualBoot ? "Connecting to the manually selected ROM bootloader…" : "Entering the bootloader and writing the factory image…"
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
            ? "Firmware is installed. Unplug tinyTouch, then plug it back in to continue setup."
            : "Factory image verified. Reconnect tinyTouch normally to finish factory-default verification."
    }

    private static func download(_ url: URL) async throws -> Data {
        let (data, response) = try await URLSession.shared.data(from: url)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw FirmwareError.invalid("Firmware server returned an error.") }
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
        } catch { state.error = error.localizedDescription; setup = state; return }
        state.mode = mode; state.phase = .authenticate; state.message = "Authorizing device setup…"
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
        state.mode = nil; state.phase = .chooseMode; state.message = "Choose how you want to use tinyTouch."
        state.error = nil; state.provisioningComplete = false; state.canSkipPairing = false; state.pairingStarted = false
        setupPassword = nil; setupKey = nil; setup = state
    }

    func skipPIVPairing() {
        guard var state = setup, state.mode == .piv, state.provisioningComplete, state.canSkipPairing else { return }
        state.phase = .complete; state.message = "PIV is ready. macOS pairing was skipped."
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
        perform(deviceID: id) { [self] in try await readStatus(id: id); return "Status updated." }
    }

    func setHIDSettings(typingDelayMS: Int, submitEnter: Bool, touchCooldownMS: Int) {
        guard let id = selectedID else { return }
        perform(deviceID: id) { [self] in
            guard (1...100).contains(typingDelayMS), (100...5000).contains(touchCooldownMS) else {
                throw DeviceError.response("HID settings are outside the supported range.")
            }
            let current = try await status(id: id)
            guard current.protocolVersion == 6, current.mode == "hid",
                  current.typingDelayMS != nil, current.submitEnter != nil, current.touchCooldownMS != nil else {
                throw DeviceError.response("Update this device to firmware that supports HID settings.")
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
                throw DeviceError.response("The device did not confirm the new HID settings.")
            }
            return "HID settings saved."
        }
    }

    func changeMode(to mode: SetupMode) {
        guard let id = selectedID, let device = selectedDevice else { return }
        perform(deviceID: id) { [self] in
            let current = try await status(id: id)
            guard current.protocolVersion == 6 else {
                throw DeviceError.response("Mode changes require protocol 6 firmware.")
            }
            guard current.sensorReady else { throw DeviceError.response("The fingerprint sensor is not responding.") }
            guard current.mode != mode.rawValue else { return "tinyTouch is already in \(mode.rawValue.uppercased()) mode." }

            var provisioned = current.isProvisioned(mode: mode)
            if provisioned && mode == .hid {
                let hosts = try await hostList(id, dialect: current.dialect)
                let key = try await pairingKey(id)
                let hasLocalPassword = try await hasPassword(id)
                provisioned = try key.map { hosts.ids.contains(try HIDProtocol.keyID($0)) } == true && hasLocalPassword
            }
            if !provisioned {
                setup = DeviceSetupState(deviceID: id, deviceName: device.name, mode: mode,
                                         message: "Complete \(mode.rawValue.uppercased()) setup to switch modes.")
                return nil
            }

            try await unlock(id, dialect: current.dialect)
            guard let command = current.dialect.setMode(mode) else {
                throw DeviceError.response("Mode changes require protocol 6 firmware.")
            }
            _ = try await manager.command(deviceID: id, command)
            _ = try await waitForStatus(id: id, mode: mode)
            _ = try await readStatus(id: id)
            if mode == .hid { manager.markReady(id) }
            return "Switched tinyTouch to \(mode.rawValue.uppercased()) mode. Existing PIV and HID data was preserved."
        }
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
    func factoryReset() {
        guard !busy, let id = selectedID else { return }
        busy = true; setAppMessage(nil)
        Task {
            defer { clearFingerprintPrompt(deviceID: id); busy = false }
            do {
                let current = try await self.status(id: id)
                guard let command = current.dialect.factoryReset else {
                    throw DeviceError.response("Factory reset requires protocol 6 firmware.")
                }
                guard current.sensorReady else {
                    throw DeviceError.response("The fingerprint sensor must be available to erase its templates.")
                }
                try await unlock(id, dialect: current.dialect)
                _ = try await manager.command(deviceID: id, command, timeout: 15)
                do {
                    guard try await status(id: id).isFactoryDefault else {
                        throw DeviceError.response("Factory reset verification failed; local data was preserved.")
                    }
                    try await deleteLocalData(id)
                } catch {
                    manager.reconnect(id); throw error
                }
                manager.reconnect(id)
                setAppMessage("Factory reset completed. Device and local credentials were erased.")
            } catch { failApp(error) }
        }
    }
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
        guard !isFirmwareWriting, let id = selectedID else { return }
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
            if let error = errors[identity.id] { device.message = error.localizedDescription; device.isError = true }
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
                    guard current.isFactoryDefault else { throw FirmwareError.invalid("Flashed device did not return in factory-default state; local credentials were preserved.") }
                    try await deleteLocalData(pending.id)
                    firmware.phase = .complete; firmware.message = "Factory flash verified. Device data and matching local credentials were reset."
                } catch { firmware.phase = .failed; firmware.error = error.localizedDescription; firmware.message = "Post-flash verification failed." }
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
        firmware.message = "Resetting tinyTouch to factory defaults…"
        Task {
            defer { newBoardFactoryResetting = false; busy = false }
            do {
                guard let command = status.dialect.factoryReset else {
                    throw DeviceError.response("Factory reset requires protocol 6 firmware.")
                }
                guard status.sensorReady else {
                    throw DeviceError.response("The fingerprint sensor must be available to factory-reset tinyTouch.")
                }
                try await unlock(id, dialect: status.dialect)
                _ = try await manager.command(deviceID: id, command, timeout: 15)
                let current = try await self.status(id: id)
                guard current.isFactoryDefault else {
                    throw DeviceError.response("Factory reset verification failed.")
                }
                newBoardFlashActive = false; newBoardFlashLocationID = nil; defaults.removeObject(forKey: "newBoardFlashLocationID"); showFlashOnboarding = false
                beginSetupIfNeeded(current, id: id)
            } catch {
                firmware.phase = .failed; firmware.error = error.localizedDescription
                firmware.message = "Factory reset stopped safely."
            }
        }
    }

    private func runSetup() {
        guard !busy, let state = setup, let mode = state.mode else { return }
        busy = true; updateSetup(.authenticate, "Authorizing device setup…")
        Task {
            do {
                let id = state.deviceID
                var current = try await status(id: id)
                guard current.protocolVersion == 6 else { throw DeviceError.response("Setup requires protocol 6 firmware.") }
                guard current.sensorReady else { throw DeviceError.response("The fingerprint sensor is not responding.") }
                try await unlock(id, dialect: current.dialect)
                if mode == .hid {
                    updateSetup(.registerMac, "Registering this Mac securely…")
                    let storedKey = try await pairingKey(id)
                    let key: Data
                    if let setupKey { key = setupKey }
                    else if let storedKey { key = storedKey }
                    else { key = try await randomKeyOffMain() }
                    setupKey = key
                    let hosts = try await hostList(id, dialect: current.dialect), hostID = try await keyID(key)
                    if !hosts.ids.contains(hostID) {
                        guard hosts.capacity == 0 || hosts.ids.count < hosts.capacity else {
                            throw DeviceError.response("The device already trusts its maximum number of HID computers.")
                        }
                        _ = try await manager.command(deviceID: id, current.dialect.hostAdd(id: hostID, key: key.hex))
                    }
                    if let password = setupPassword {
                        try await saveCredentials(key: key, password: password, id: id); setupPassword = nil
                    } else if !(try await hasPassword(id)) {
                        throw DeviceError.response("Enter the password again to resume setup.")
                    }
                }
                if current.mode != mode.rawValue {
                    updateSetup(.switchMode, "Switching tinyTouch to \(mode.rawValue.uppercased()) mode…")
                    guard let command = current.dialect.setMode(mode) else { throw DeviceError.response("Mode changes require protocol 6 firmware.") }
                    _ = try await manager.command(deviceID: id, command)
                    current = try await waitForStatus(id: id, mode: mode)
                }
                try await unlock(id, dialect: current.dialect)
                if mode == .piv && current.fields["piv"] != "ready" {
                    updateSetup(.createIdentity, "Creating the PIV identity…")
                    guard let command = current.dialect.pivCreate else { throw DeviceError.response("PIV setup requires protocol 6 firmware.") }
                    _ = try await manager.command(deviceID: id, command, timeout: 90)
                    current = try await status(id: id)
                    guard current.fields["piv"] == "ready" else { throw DeviceError.response("The PIV identity was not created.") }
                }
                if current.fingerprintCount == 0 {
                    updateSetup(.enroll, "Touch the sensor to enroll your fingerprint.")
                    showPrompt("PROMPT TOUCH", deviceID: id)
                    defer { clearFingerprintPrompt(deviceID: id) }
                    _ = try await manager.command(deviceID: id, current.dialect.enroll(slot: 1), timeout: 50)
                }
                updateSetup(.verify, "Verifying setup…")
                current = try await readStatus(id: id)
                guard current.isSetupComplete(mode: mode) else { throw DeviceError.response("Setup verification did not report an enrolled fingerprint and a ready \(mode.rawValue.uppercased()) configuration.") }
                if mode == .hid {
                    guard let key = try await pairingKey(id), try await hasPassword(id) else { throw DeviceError.missingCredentials }
                    let hosts = try await hostList(id, dialect: current.dialect)
                    guard hosts.ids.contains(try await keyID(key)) else { throw DeviceError.response("This Mac was not found in the HID host list.") }
                    manager.markReady(id); completeSetup("HID is ready with your fingerprint.")
                } else {
                    if var setup {
                        setup.phase = .pair; setup.provisioningComplete = true; setup.canSkipPairing = true
                        setup.message = "Unplug tinyTouch, plug it back in, then pair it with macOS."
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
        throw DeviceError.response(mode.map { "tinyTouch did not reconnect in \($0.rawValue.uppercased()) mode." } ?? "tinyTouch did not reconnect.")
    }

    func pairPIV() {
        guard !busy, setup?.mode == .piv else { return }
        busy = true; updateSetup(.pair, "Opening macOS PIV pairing…")
        Task {
            let failure = await Task.detached { Self.runPIVPairing() }.value
            if let failure, var state = setup { state.recordPairingFailure(failure); setup = state }
            else if var state = setup {
                state.pairingStarted = true
                state.message = "When macOS asks for a PIN, touch tinyTouch; do not type the PIN manually."
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
            catch { return (-1, "", error.localizedDescription) }
            return (process.terminationStatus,
                    String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self),
                    String(decoding: error.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
        }
        let deadline = Date().addingTimeInterval(10)
        var failure = "macOS did not discover the tinyTouch PIV identity. Unplug and reconnect tinyTouch, then choose Retry."
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
        completeSetup("PIV is ready and paired with macOS.")
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
        state.error = error.localizedDescription; setup = state
    }
    private func status(id: String) async throws -> DeviceStatus {
        let lines = try await manager.command(deviceID: id, "STATUS")
        guard let line = lines.last(where: { $0.hasPrefix("OK STATUS ") }) else { throw DeviceError.response("No STATUS response received.") }
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
        let messages = ["PROMPT TOUCH": "Touch the fingerprint sensor now.", "PROMPT LIFT": "Lift your finger.",
                        "PROMPT TOUCH_AGAIN": "Touch the sensor with the same finger again.",
                        "EVENT TOUCH": "Touch the fingerprint sensor now."]
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
                throw DeviceError.response("The device was reset, but some local data could not be erased: \(firstError.localizedDescription)")
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
