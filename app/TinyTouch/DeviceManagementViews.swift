import SwiftUI

struct OverviewView: View {
    @EnvironmentObject private var app: AppState
    @State private var showingRawValues = false
    @State private var rawValues = "{}"
    var body: some View { Page(title: "nav_overview", icon: "dot.radiowaves.left.and.right") { availableDevice(app) { device, status in
        Grid(alignment: .leading, horizontalSpacing: 28, verticalSpacing: 12) {
            row("device_connection", device.connection.rawValue)
            ForEach(status.fields.keys.sorted(), id: \.self) { key in row(DeviceStatus.label(for: key), status.fields[key]!, key: key) }
        }
        Button("view_raw_values") { rawValues = status.rawJSON; showingRawValues = true }
        DeviceMessageView()
    } }.sheet(isPresented: $showingRawValues) { VStack(alignment: .leading) {
        Text("raw_values").font(.headline)
        ScrollView { Text(rawValues).font(.system(.body, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
        HStack { Spacer(); Button("common_close") { showingRawValues = false } }
    }.padding().frame(minWidth: 420, minHeight: 300) } }
    private func row(_ label: String, _ value: String, key: String? = nil) -> some View { GridRow { Text(L10n.text(label)).foregroundStyle(.secondary); Text(L10n.deviceValue(key, value)).textSelection(.enabled) } }
}

struct HIDSetupView: View {
    @EnvironmentObject private var app: AppState
    @State private var password = ""
    @State private var confirmation = ""
    @State private var enroll = true
    @State private var editing = false
    var body: some View { Page(title: "nav_hid_setup", icon: "keyboard") { availableDevice(app) { device, status in
        if status.mode != "hid" { RequirementPlaceholder(icon: "arrow.triangle.2.circlepath", title: "switch_tinytouch_hid_mode", description: "switch_modes_return_here") }
        else if !status.sensorReady { RequirementPlaceholder(icon: "touchid", title: "fingerprint_sensor_unavailable", description: "fingerprint_sensor_hid_set") }
        else if device.connection == .ready && !editing { RequirementPlaceholder(icon: "checkmark.circle", title: "hid_ready", description: "mac_has_credentials_tinytouch", actionTitle: "update_credentials", action: { editing = true }) }
        else { setupForm(fourViews: status.dialect == .protocol6) }
    } } }
    private func setupForm(fourViews: Bool) -> some View { Group {
        Text("fingerprint_match_login_keychain").foregroundStyle(.secondary)
        SecureField("mac_account_password", text: $password).frame(maxWidth: 380); SecureField("confirm_password", text: $confirmation).frame(maxWidth: 380)
        Toggle(L10n.text(fourViews ? "enroll_four_none_exist" : "enroll_fingerprint_none_exists"), isOn: $enroll)
        Button("set_hid") { app.configureHID(password: password, confirmation: confirmation, enroll: enroll); password = ""; confirmation = "" }.buttonStyle(.borderedProminent).disabled(app.busy || password.isEmpty || password != confirmation)
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
    var body: some View { Page(title: "nav_fingerprints", icon: "touchid") { availableDevice(app) { _, status in
        if !status.sensorReady { RequirementPlaceholder(icon: "touchid", title: "fingerprint_sensor_unavailable", description: "fingerprint_sensor_manage_fingerprints") }
        else {
            Text("configuration_changes_device_secured").foregroundStyle(.secondary)
            if let count { Text(count == 1 ? L10n.text("device_reports_enrolled_fingerprint") : L10n.text("device_reports_enrolled_fingerprints", count)).foregroundStyle(.secondary) }
            if let slots, !slots.isEmpty { VStack(spacing: 0) { ForEach(slots, id: \.self) { number in HStack { Label(L10n.text("fingerprint", number), systemImage: "touchid"); Spacer(); Button("common_delete", role: .destructive) { deletion = .fingerprint(number) } }.padding(.horizontal, 8).padding(.vertical, 10).background(app.matchedFingerprint == number ? Color.gray.opacity(0.15) : .clear, in: RoundedRectangle(cornerRadius: 8)).animation(.easeOut(duration: 0.15), value: app.matchedFingerprint); if number != slots.last { Divider() } } }.disabled(app.busy) }
            if slots == nil, let count, count > 0 { Text("firmware_not_fingerprints_safely").foregroundStyle(.secondary) }
            if let nextSlot { Button("add_fingerprint") { app.enroll(slot: nextSlot) }.disabled(app.busy) }
            if let count, count > 0 { Button("delete_all_fingerprints", role: .destructive) { deletion = .all }.disabled(app.busy) }
            DeviceMessageView()
        }
    } }.onAppear { app.setFingerprintsVisible(true) }.onDisappear { app.setFingerprintsVisible(false) }.alert("delete_fingerprints", isPresented: Binding(get: { deletion != nil }, set: { if !$0 { deletion = nil } })) {
        Button("common_cancel", role: .cancel) { deletion = nil }; Button("common_delete", role: .destructive) { let target = deletion; deletion = nil; switch target { case .fingerprint(let number): app.deleteFingerprint(slot: number); case .all: app.deleteAllFingerprints(); case nil: break } }
    } message: { switch deletion { case .fingerprint(let number): Text(L10n.text("removes_fingerprint", number)); case .all: Text("removes_enrolled_fingerprint"); case nil: EmptyView() } } }
}

struct ComputersView: View {
    @EnvironmentObject private var app: AppState
    @State private var removeID: String?
    let goToSetup: () -> Void
    var body: some View { Page(title: "nav_computers", icon: "desktopcomputer") { availableDevice(app) { device, status in
        if status.mode != "hid" { RequirementPlaceholder(icon: "arrow.triangle.2.circlepath", title: "switch_tinytouch_hid_mode", description: "switch_modes_return_here") }
        else if !status.sensorReady { RequirementPlaceholder(icon: "touchid", title: "fingerprint_sensor_unavailable", description: "fingerprint_sensor_hid_computers") }
        else if status.protocolVersion < 2 { RequirementPlaceholder(icon: "desktopcomputer", title: "multiple_computers_not_supported", description: "firmware_uses_use_page") }
        else if device.connection != .ready { RequirementPlaceholder(icon: "keyboard", title: "complete_hid_setup_first", description: "mac_needs_trusted_computers", actionTitle: "go_hid_setup", action: goToSetup) }
        else {
            Text(device.hostCapacity > 0 ? L10n.text("device_trust_limit", device.hostCapacity) : L10n.text("device_trust_macs_independently")).foregroundStyle(.secondary)
            ForEach(device.hostIDs, id: \.self) { id in HStack { Image(systemName: id == device.currentMacID ? "laptopcomputer.and.checkmark" : "desktopcomputer"); Text(id).font(.system(.body, design: .monospaced)); if id == device.currentMacID { Text("mac").foregroundStyle(.secondary) }; Spacer(); Button("common_remove", role: .destructive) { removeID = id } } }
            if device.hostIDs.isEmpty { Text("no_hid_computers_reported").foregroundStyle(.secondary) }
            HStack { Button("common_refresh") { app.refreshComputers() }.disabled(app.busy); if device.currentMacID.map(device.hostIDs.contains) == true { Label("mac_trusted", systemImage: "checkmark.circle.fill").foregroundStyle(.green) } else if device.hostCapacity > 0 && device.hostIDs.count >= device.hostCapacity { Label("hid_computer_list_full", systemImage: "exclamationmark.circle").foregroundStyle(.secondary) } else { Button("add_mac") { app.addCurrentMac() }.buttonStyle(.borderedProminent).disabled(app.busy) } }
            DeviceMessageView()
        }
    } }.confirmationDialog("remove_hid_computer", isPresented: Binding(get: { removeID != nil }, set: { if !$0 { removeID = nil } })) { Button("common_remove", role: .destructive) { if let id = removeID { app.removeComputer(id: id) }; removeID = nil } } }
}

struct SettingsView: View {
    @EnvironmentObject private var app: AppState
    @State private var pendingMode: SetupMode?
    @State private var confirmingFactoryReset = false
    private var version: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? L10n.text("common_unknown") }
    var body: some View { Page(title: "nav_settings", icon: "gear") {
        HStack {
            Text("settings_language").frame(width: 132, alignment: .leading)
            Picker("", selection: Binding(get: { app.language }, set: { app.setLanguage($0) })) {
                ForEach(AppLanguage.allCases) { Text($0.title).tag($0) }
            }.id(app.language).labelsHidden()
        }
        if app.selectedMode != .piv {
            Toggle("enable_hid_background_service", isOn: Binding(get: { app.backgroundEnabled }, set: { app.setBackgroundEnabled($0) }))
            Toggle("launch_login", isOn: Binding(get: { app.launchAtLogin }, set: { app.setLaunchAtLogin($0) }))
            HStack {
                Text("settings_keyboard_mapping").frame(width: 132, alignment: .leading)
                Picker("", selection: Binding(get: { app.keyboardMode }, set: { app.setKeyboardMode($0) })) { ForEach(KeyboardMode.allCases) { Text(L10n.text($0.title)).tag($0) } }.id(app.language).labelsHidden().disabled(app.selectedDevice == nil)
            }
            if let status = app.selectedDevice?.status, status.mode == "hid" {
                Divider(); Text("hid_behavior").font(.headline)
                if let delay = status.typingDelayMS, let submit = status.submitEnter, let cooldown = status.touchCooldownMS {
                    HIDDeviceSettingsView(typingDelayMS: delay, submitEnter: submit, touchCooldownMS: cooldown)
                        .id("\(app.selectedID ?? "")-\(delay)-\(submit)-\(cooldown)")
                } else {
                    Text("update_device_hid_settings").foregroundStyle(.secondary)
                }
            }
        }
        if let idleLEDOn = app.selectedDevice?.status?.idleLEDOn {
            Divider(); Text("device_behavior").font(.headline)
            IdleLEDSettingsView(enabled: idleLEDOn)
                .id("\(app.selectedID ?? "")-\(idleLEDOn)")
        }
        Divider(); Text("device_mode").font(.headline)
        if let status = app.selectedDevice?.status, let current = SetupMode(rawValue: status.mode) {
            let target: SetupMode = current == .hid ? .piv : .hid
            Text(L10n.text("current_mode", current.rawValue.uppercased())).foregroundStyle(.secondary)
            Button(L10n.text("switch", target.rawValue.uppercased())) { pendingMode = target }
                .buttonStyle(.borderedProminent)
                .disabled(app.busy || !app.backgroundEnabled || app.selectedDevice?.connection == .error || status.protocolVersion != 6 || !status.sensorReady)
            if status.protocolVersion != 6 { Text("update_device_switch_modes").foregroundStyle(.secondary) }
            else if !status.sensorReady { Text("fingerprint_sensor_mode_change").foregroundStyle(.secondary) }
        } else { Text("connect_compatible_switch_modes").foregroundStyle(.secondary) }
        if app.legacyHelperDetected { ForEach(app.legacyOwners) { Text($0.detail).font(.system(.caption, design: .monospaced)).textSelection(.enabled) }; Button("replace_legacy_helper") { app.replaceLegacyHelper() }.buttonStyle(.borderedProminent) }
        if app.selectedMode == .hid { Text("passwords_pairing_support_tinytouch").foregroundStyle(.secondary) }
        Button("export_diagnostics") { app.exportDiagnostics() }; Divider(); Text("settings_factory_reset").font(.headline)
        Text("erase_fingerprints_selected_tinytouch").foregroundStyle(.secondary)
        Button("settings_factory_reset", role: .destructive) { confirmingFactoryReset = true }.disabled(app.busy || !app.backgroundEnabled || app.selectedDevice?.connection == .error || app.selectedDevice?.status?.protocolVersion != 6 || app.selectedDevice?.status?.sensorReady != true)
        if let status = app.selectedDevice?.status, status.protocolVersion != 6 { Text("update_device_factory_reset").foregroundStyle(.secondary) } else if app.selectedDevice?.status?.sensorReady == false { Text("fingerprint_sensor_templates_erased").foregroundStyle(.secondary) }
        AppMessageView(); Divider(); Text("settings_about").font(.headline)
        LabeledContent("settings_version", value: version).textSelection(.enabled)
    }.confirmationDialog("switch_tinytouch_mode", isPresented: Binding(get: { pendingMode != nil }, set: { if !$0 { pendingMode = nil } }), titleVisibility: .visible) {
        Button("common_cancel", role: .cancel) { pendingMode = nil }
        if let mode = pendingMode { Button(L10n.text("switch", mode.rawValue.uppercased())) { pendingMode = nil; app.changeMode(to: mode) } }
    } message: { Text("touch_fingerprint_credentials_preserved") }
    .alert("factory_reset_selected_tinytouch", isPresented: $confirmingFactoryReset) { Button("common_cancel", role: .cancel) {}; Button("settings_factory_reset", role: .destructive) { app.factoryReset() } } message: { Text("permanently_erases_also_deleted") } }
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
        Toggle("keep_fingerprint_led_idle", isOn: $enabled)
        Button("common_apply") { app.setIdleLED(enabled) }
            .buttonStyle(.borderedProminent)
            .disabled(app.busy || !app.backgroundEnabled || enabled == originalEnabled)
        Text("default_applying_fingerprint_authorization").foregroundStyle(.secondary)
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
        Stepper(L10n.text("typing_delay_ms", typingDelayMS), value: $typingDelayMS, in: 1...100)
        Toggle("press_enter_typing", isOn: $submitEnter)
        Stepper(L10n.text("touch_cooldown_ms", touchCooldownMS), value: $touchCooldownMS, in: 100...5000, step: 100)
        Button("common_apply") { app.setHIDSettings(typingDelayMS: typingDelayMS, submitEnter: submitEnter, touchCooldownMS: touchCooldownMS) }
            .buttonStyle(.borderedProminent)
            .disabled(app.busy || !app.backgroundEnabled ||
                      (typingDelayMS == originalTypingDelayMS && submitEnter == originalSubmitEnter && touchCooldownMS == originalTouchCooldownMS))
        Text("applying_requires_effect_immediately").foregroundStyle(.secondary)
    }
}
