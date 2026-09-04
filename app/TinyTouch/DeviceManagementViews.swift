import SwiftUI

struct OverviewView: View {
    @EnvironmentObject private var app: AppState
    var body: some View { Page(title: "Overview", icon: "dot.radiowaves.left.and.right") { availableDevice(app) { device, status in
        Grid(alignment: .leading, horizontalSpacing: 28, verticalSpacing: 12) {
            row("Connection", device.connection.rawValue)
            ForEach(status.fields.keys.sorted(), id: \.self) { key in row(DeviceStatus.label(for: key), status.fields[key]!) }
        }
        DeviceMessageView()
    } } }
    private func row(_ label: String, _ value: String) -> some View { GridRow { Text(label).foregroundStyle(.secondary); Text(value).textSelection(.enabled) } }
}

struct HIDSetupView: View {
    @EnvironmentObject private var app: AppState
    @State private var password = ""
    @State private var confirmation = ""
    @State private var enroll = true
    @State private var editing = false
    var body: some View { Page(title: "HID Setup", icon: "keyboard") { availableDevice(app) { device, status in
        if status.mode != "hid" { RequirementPlaceholder(icon: "arrow.triangle.2.circlepath", title: "Switch tinyTouch to HID mode", description: "Switch modes in Settings, then return here.") }
        else if !status.sensorReady { RequirementPlaceholder(icon: "touchid", title: "Fingerprint sensor unavailable", description: "The fingerprint sensor must be working before HID can be set up.") }
        else if device.connection == .ready && !editing { RequirementPlaceholder(icon: "checkmark.circle", title: "HID is ready", description: "This Mac has HID credentials for tinyTouch.", actionTitle: "Update Credentials", action: { editing = true }) }
        else { setupForm(fourViews: status.dialect == .protocol6) }
    } } }
    private func setupForm(fourViews: Bool) -> some View { Group {
        Text("After a fingerprint match, tinyTouch securely asks this Mac to type the password stored in your login Keychain.").foregroundStyle(.secondary)
        SecureField("Mac account password", text: $password).frame(maxWidth: 380); SecureField("Confirm password", text: $confirmation).frame(maxWidth: 380)
        Toggle(fourViews ? "Enroll four fingerprint views if none exist" : "Enroll fingerprint in slot 1 if none exists", isOn: $enroll)
        Button("Set Up HID") { app.configureHID(password: password, confirmation: confirmation, enroll: enroll); password = ""; confirmation = "" }.buttonStyle(.borderedProminent).disabled(app.busy || password.isEmpty || password != confirmation)
        DeviceMessageView()
    } }
}

struct FingerprintsView: View {
    @EnvironmentObject private var app: AppState
    @State private var deletion: Deletion?
    private var count: Int? { app.selectedDevice?.status?.fingerprintCount.map { min(max($0, 0), 5) } }
    private var slots: [Int]? { app.selectedDevice?.status?.fingerprintSlots }
    private var nextSlot: Int? { app.selectedDevice?.status?.nextFingerprintSlot }
    enum Deletion: Identifiable { case fingerprint(Int), all; var id: String { switch self { case .fingerprint(let number): "fingerprint-\(number)"; case .all: "all" } } }
    var body: some View { Page(title: "Fingerprints", icon: "touchid") { availableDevice(app) { _, status in
        if !status.sensorReady { RequirementPlaceholder(icon: "touchid", title: "Fingerprint sensor unavailable", description: "The fingerprint sensor must be working to manage fingerprints.") }
        else {
            Text("Configuration changes require an enrolled fingerprint when the device is already secured.").foregroundStyle(.secondary)
            if let count { Text("Device reports \(count) enrolled fingerprint\(count == 1 ? "" : "s").").foregroundStyle(.secondary) }
            if let slots, !slots.isEmpty { VStack(spacing: 0) { ForEach(slots, id: \.self) { number in HStack { Label("Fingerprint \(number)", systemImage: "touchid"); Spacer(); Button("Delete", role: .destructive) { deletion = .fingerprint(number) } }.padding(.horizontal, 8).padding(.vertical, 10).background(app.matchedFingerprint == number ? Color.gray.opacity(0.15) : .clear, in: RoundedRectangle(cornerRadius: 8)).animation(.easeOut(duration: 0.15), value: app.matchedFingerprint); if number != slots.last { Divider() } } }.disabled(app.busy) }
            if slots == nil, let count, count > 0 { Text("This firmware does not report fingerprint slot IDs. Update firmware to manage individual fingerprints safely.").foregroundStyle(.secondary) }
            if let nextSlot { Button("Add Fingerprint") { app.enroll(slot: nextSlot) }.disabled(app.busy) }
            if let count, count > 0 { Button("Delete All Fingerprints", role: .destructive) { deletion = .all }.disabled(app.busy) }
            DeviceMessageView()
        }
    } }.onAppear { app.setFingerprintsVisible(true) }.onDisappear { app.setFingerprintsVisible(false) }.alert("Delete fingerprints?", isPresented: Binding(get: { deletion != nil }, set: { if !$0 { deletion = nil } })) {
        Button("Cancel", role: .cancel) { deletion = nil }; Button("Delete", role: .destructive) { let target = deletion; deletion = nil; switch target { case .fingerprint(let number): app.deleteFingerprint(slot: number); case .all: app.deleteAllFingerprints(); case nil: break } }
    } message: { switch deletion { case .fingerprint(let number): Text("This removes Fingerprint \(number)."); case .all: Text("This removes every enrolled fingerprint."); case nil: EmptyView() } } }
}

struct ComputersView: View {
    @EnvironmentObject private var app: AppState
    @State private var removeID: String?
    let goToSetup: () -> Void
    var body: some View { Page(title: "Computers", icon: "desktopcomputer") { availableDevice(app) { device, status in
        if status.mode != "hid" { RequirementPlaceholder(icon: "arrow.triangle.2.circlepath", title: "Switch tinyTouch to HID mode", description: "Switch modes in Settings, then return here.") }
        else if !status.sensorReady { RequirementPlaceholder(icon: "touchid", title: "Fingerprint sensor unavailable", description: "The fingerprint sensor must be working to manage HID computers.") }
        else if status.protocolVersion < 2 { RequirementPlaceholder(icon: "desktopcomputer", title: "Multiple computers are not supported", description: "This firmware uses protocol 1 and supports only one HID computer. Update firmware outside TinyTouch to use this page.") }
        else if device.connection != .ready { RequirementPlaceholder(icon: "keyboard", title: "Complete HID Setup first", description: "This Mac needs HID credentials before it can manage trusted computers.", actionTitle: "Go to HID Setup", action: goToSetup) }
        else {
            Text(device.hostCapacity > 0 ? "This device can trust up to \(device.hostCapacity) Macs independently." : "This device can trust multiple Macs independently.").foregroundStyle(.secondary)
            ForEach(device.hostIDs, id: \.self) { id in HStack { Image(systemName: id == device.currentMacID ? "laptopcomputer.and.checkmark" : "desktopcomputer"); Text(id).font(.system(.body, design: .monospaced)); if id == device.currentMacID { Text("This Mac").foregroundStyle(.secondary) }; Spacer(); Button("Remove", role: .destructive) { removeID = id } } }
            if device.hostIDs.isEmpty { Text("No HID computers reported.").foregroundStyle(.secondary) }
            HStack { Button("Refresh") { app.refreshComputers() }.disabled(app.busy); if device.currentMacID.map(device.hostIDs.contains) == true { Label("This Mac is trusted", systemImage: "checkmark.circle.fill").foregroundStyle(.green) } else if device.hostCapacity > 0 && device.hostIDs.count >= device.hostCapacity { Label("The HID computer list is full", systemImage: "exclamationmark.circle").foregroundStyle(.secondary) } else { Button("Add This Mac") { app.addCurrentMac() }.buttonStyle(.borderedProminent).disabled(app.busy) } }
            DeviceMessageView()
        }
    } }.confirmationDialog("Remove this HID computer?", isPresented: Binding(get: { removeID != nil }, set: { if !$0 { removeID = nil } })) { Button("Remove", role: .destructive) { if let id = removeID { app.removeComputer(id: id) }; removeID = nil } } }
}

struct SettingsView: View {
    @EnvironmentObject private var app: AppState
    @State private var pendingMode: SetupMode?
    @State private var confirmingFactoryReset = false
    private var version: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Unknown" }
    var body: some View { Page(title: "Settings", icon: "gear") {
        if app.selectedMode != .piv {
            Toggle("Enable HID background service", isOn: Binding(get: { app.backgroundEnabled }, set: { app.setBackgroundEnabled($0) }))
            Toggle("Launch at login", isOn: Binding(get: { app.launchAtLogin }, set: { app.setLaunchAtLogin($0) }))
            Picker("Keyboard mapping", selection: Binding(get: { app.keyboardMode }, set: { app.setKeyboardMode($0) })) { ForEach(KeyboardMode.allCases) { Text($0.title).tag($0) } }.frame(maxWidth: 360).disabled(app.selectedDevice == nil)
            if let status = app.selectedDevice?.status, status.mode == "hid" {
                Divider(); Text("HID Behavior").font(.headline)
                if let delay = status.typingDelayMS, let submit = status.submitEnter, let cooldown = status.touchCooldownMS {
                    HIDDeviceSettingsView(typingDelayMS: delay, submitEnter: submit, touchCooldownMS: cooldown)
                        .id("\(app.selectedID ?? "")-\(delay)-\(submit)-\(cooldown)")
                } else {
                    Text("Update this device to firmware that reports HID settings.").foregroundStyle(.secondary)
                }
            }
        }
        if let idleLEDOn = app.selectedDevice?.status?.idleLEDOn {
            Divider(); Text("Device Behavior").font(.headline)
            IdleLEDSettingsView(enabled: idleLEDOn)
                .id("\(app.selectedID ?? "")-\(idleLEDOn)")
        }
        Divider(); Text("Device Mode").font(.headline)
        if let status = app.selectedDevice?.status, let current = SetupMode(rawValue: status.mode) {
            let target: SetupMode = current == .hid ? .piv : .hid
            Text("Current mode: \(current.rawValue.uppercased())").foregroundStyle(.secondary)
            Button("Switch to \(target.rawValue.uppercased())") { pendingMode = target }
                .buttonStyle(.borderedProminent)
                .disabled(app.busy || !app.backgroundEnabled || app.selectedDevice?.connection == .error || status.protocolVersion != 6 || !status.sensorReady)
            if status.protocolVersion != 6 { Text("Update this device to protocol 6 firmware to switch modes.").foregroundStyle(.secondary) }
            else if !status.sensorReady { Text("The fingerprint sensor must be available to authorize a mode change.").foregroundStyle(.secondary) }
        } else { Text("Connect a compatible tinyTouch to switch modes.").foregroundStyle(.secondary) }
        if app.legacyHelperDetected { ForEach(app.legacyOwners) { Text($0.detail).font(.system(.caption, design: .monospaced)).textSelection(.enabled) }; Button("Replace Legacy Helper") { app.replaceLegacyHelper() }.buttonStyle(.borderedProminent) }
        if app.selectedMode == .hid { Text("Passwords and pairing keys are stored only in your macOS Keychain. Replay state remains in ~/Library/Application Support/tinyTouch.").foregroundStyle(.secondary) }
        Button("Export Diagnostics…") { app.exportDiagnostics() }; Divider(); Text("Factory Reset").font(.headline)
        Text("Erase fingerprints, PIV keys, trusted computers, device settings, and this Mac's credentials for the selected tinyTouch.").foregroundStyle(.secondary)
        Button("Factory Reset", role: .destructive) { confirmingFactoryReset = true }.disabled(app.busy || !app.backgroundEnabled || app.selectedDevice?.connection == .error || app.selectedDevice?.status?.protocolVersion != 6 || app.selectedDevice?.status?.sensorReady != true)
        if let status = app.selectedDevice?.status, status.protocolVersion != 6 { Text("Update this device to protocol 6 firmware to use Factory Reset.").foregroundStyle(.secondary) } else if app.selectedDevice?.status?.sensorReady == false { Text("The fingerprint sensor must be available so its templates can be erased.").foregroundStyle(.secondary) }
        AppMessageView(); Divider(); Text("About").font(.headline)
        LabeledContent("Version", value: version).textSelection(.enabled)
    }.confirmationDialog("Switch tinyTouch mode?", isPresented: Binding(get: { pendingMode != nil }, set: { if !$0 { pendingMode = nil } }), titleVisibility: .visible) {
        Button("Cancel", role: .cancel) { pendingMode = nil }
        if let mode = pendingMode { Button("Switch to \(mode.rawValue.uppercased())") { pendingMode = nil; app.changeMode(to: mode) } }
    } message: { Text("Touch the fingerprint sensor to authorize the change. Existing PIV keys, HID computers, fingerprints, and credentials will be preserved.") }
    .alert("Factory reset selected tinyTouch?", isPresented: $confirmingFactoryReset) { Button("Cancel", role: .cancel) {}; Button("Factory Reset", role: .destructive) { app.factoryReset() } } message: { Text("This permanently erases every fingerprint, PIV key, trusted computer, and device setting. TinyTouch will return to its unconfigured PIV state. Matching credentials and settings on this Mac will also be deleted.") } }
}

private struct IdleLEDSettingsView: View {
    @EnvironmentObject private var app: AppState
    let originalEnabled: Bool
    @State private var enabled: Bool

    init(enabled: Bool) {
        originalEnabled = enabled
        _enabled = State(initialValue: enabled)
    }

    var body: some View {
        Toggle("Keep fingerprint LED on while idle", isOn: $enabled)
        Button("Apply") { app.setIdleLED(enabled) }
            .buttonStyle(.borderedProminent)
            .disabled(app.busy || !app.backgroundEnabled || enabled == originalEnabled)
        Text("On by default. Applying requires fingerprint authorization.").foregroundStyle(.secondary)
    }
}

private struct HIDDeviceSettingsView: View {
    @EnvironmentObject private var app: AppState
    let originalTypingDelayMS: Int
    let originalSubmitEnter: Bool
    let originalTouchCooldownMS: Int
    @State private var typingDelayMS: Int
    @State private var submitEnter: Bool
    @State private var touchCooldownMS: Int

    init(typingDelayMS: Int, submitEnter: Bool, touchCooldownMS: Int) {
        originalTypingDelayMS = typingDelayMS; originalSubmitEnter = submitEnter
        originalTouchCooldownMS = touchCooldownMS
        _typingDelayMS = State(initialValue: typingDelayMS); _submitEnter = State(initialValue: submitEnter)
        _touchCooldownMS = State(initialValue: touchCooldownMS)
    }

    var body: some View {
        Stepper("Typing delay: \(typingDelayMS) ms", value: $typingDelayMS, in: 1...100)
        Toggle("Press Enter after typing", isOn: $submitEnter)
        Stepper("Touch cooldown: \(touchCooldownMS) ms", value: $touchCooldownMS, in: 100...5000, step: 100)
        Button("Apply") { app.setHIDSettings(typingDelayMS: typingDelayMS, submitEnter: submitEnter, touchCooldownMS: touchCooldownMS) }
            .buttonStyle(.borderedProminent)
            .disabled(app.busy || !app.backgroundEnabled ||
                      (typingDelayMS == originalTypingDelayMS && submitEnter == originalSubmitEnter && touchCooldownMS == originalTouchCooldownMS))
        Text("Applying requires fingerprint authorization and takes effect immediately.").foregroundStyle(.secondary)
    }
}
