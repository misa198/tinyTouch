import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var app: AppState
    @State private var section = Section.overview
    enum Section: String, CaseIterable, Identifiable {
        case overview = "Overview", setup = "HID Setup", fingerprints = "Fingerprints", computers = "Computers", settings = "Settings"
        var id: Self { self }
        var icon: String {
            switch self {
            case .overview: "dot.radiowaves.left.and.right"
            case .setup: "keyboard"
            case .fingerprints: "touchid"
            case .computers: "desktopcomputer"
            case .settings: "gear"
            }
        }
    }
    var body: some View {
        ZStack {
            LiquidBackdrop()
            if !app.onboardingComplete { OnboardingView() } else {
                NavigationSplitView {
                    List(Section.allCases, selection: $section) {
                        Label($0.rawValue, systemImage: $0.icon)
                            .fontWeight(section == $0 ? .semibold : .regular)
                            .padding(.vertical, 6)
                            .tag($0)
                            .listRowBackground(Color.clear)
                    }
                    .safeAreaInset(edge: .top) {
                        HStack(spacing: 10) {
                            Image("TinyTouchIcon")
                                .resizable().scaledToFit()
                                .frame(width: 38, height: 38)
                            Text("TinyTouch").font(.headline)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 12).padding(.vertical, 10)
                    }
                    .scrollContentBackground(.hidden)
                    .background(.ultraThinMaterial)
                    .navigationSplitViewColumnWidth(min: 170, ideal: 190)
                } detail: {
                    VStack(spacing: 0) { DevicePicker(); detail }
                        .background(Color.clear)
                        .ignoresSafeArea(edges: .top)
                }
            }
        }.frame(minWidth: 720, minHeight: 480)
    }
    @ViewBuilder private var detail: some View {
        switch section {
        case .overview: OverviewView()
        case .setup: HIDSetupView()
        case .fingerprints: FingerprintsView()
        case .computers: ComputersView { section = .setup }
        case .settings: SettingsView()
        }
    }
}

private struct DevicePicker: View {
    @EnvironmentObject private var app: AppState
    var body: some View {
        HStack(spacing: 12) {
            if app.devices.count > 1 {
                Picker("Device", selection: $app.selectedID) {
                    ForEach(app.devices) { Text($0.name).tag(Optional($0.id)) }
                }.frame(maxWidth: 360)
            } else {
                VStack(alignment: .leading, spacing: 2) {
                    Text(app.selectedDevice?.name ?? "No tinyTouch connected").font(.headline)
                    Label(status, systemImage: "circle.fill")
                        .font(.caption).foregroundStyle(statusColor)
                        .labelStyle(.titleAndIcon)
                }
            }
            Spacer(); if app.busy { ProgressView().controlSize(.small) }
            Button { app.refresh() } label: { Image(systemName: "arrow.clockwise") }
                .help("Refresh or retry this device").disabled(app.selectedDevice == nil || app.busy)
        }
        .padding(.horizontal, 22).padding(.vertical, 13)
        .background(.thinMaterial)
        .overlay(alignment: .bottom) { Rectangle().fill(.white.opacity(0.14)).frame(height: 1) }
    }

    private var status: String { app.selectedDevice?.connection.rawValue.capitalized ?? "Connect a device" }
    private var statusColor: Color {
        switch app.selectedDevice?.connection {
        case .ready: .green
        case .error: .red
        case .connected: .orange
        default: .secondary
        }
    }
}

private struct Page<Content: View>: View {
    let title: String
    let icon: String
    @ViewBuilder let content: Content
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                HStack(spacing: 14) {
                    Image(systemName: icon)
                        .font(.title2.bold()).foregroundStyle(.tint)
                        .frame(width: 44, height: 44)
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    Text(title).font(.largeTitle.bold())
                }
                VStack(alignment: .leading, spacing: 18) { content }
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxWidth: 820, alignment: .leading)
            .padding(28)
        }
        .scrollContentBackground(.hidden)
    }
}

private struct DeviceMessageView: View {
    @EnvironmentObject private var app: AppState
    var body: some View {
        if let message = app.selectedDevice?.message {
            Label(message, systemImage: app.selectedDevice?.isError == true ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                .foregroundStyle(app.selectedDevice?.isError == true ? .red : .green)
                .textSelection(.enabled)
        }
    }
}

private struct AppMessageView: View {
    @EnvironmentObject private var app: AppState
    var body: some View {
        if let message = app.appMessage {
            Label(message, systemImage: app.appMessageIsError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                .foregroundStyle(app.appMessageIsError ? .red : .green)
                .textSelection(.enabled)
        }
    }
}

private struct RequirementPlaceholder: View {
    let icon: String
    let title: String
    let description: String
    var actionTitle: String?
    var action: (() -> Void)?

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: icon).font(.system(size: 40)).foregroundStyle(.secondary)
            Text(title).font(.title2.bold())
            Text(description).foregroundStyle(.secondary).multilineTextAlignment(.center)
            if let actionTitle, let action {
                Button(actionTitle, action: action).buttonStyle(.borderedProminent)
            }
        }
        .frame(maxWidth: .infinity).padding(.vertical, 60)
    }
}

@MainActor @ViewBuilder private func availableDevice<Content: View>(
    _ app: AppState,
    @ViewBuilder content: (DeviceViewState, DeviceStatus) -> Content
) -> some View {
    if !app.backgroundEnabled {
        RequirementPlaceholder(icon: "pause.circle", title: "HID service is paused",
            description: "Enable the HID service to communicate with tinyTouch.",
            actionTitle: "Enable HID Service", action: { app.setBackgroundEnabled(true) })
    } else if let device = app.selectedDevice {
        if device.connection == .error {
            RequirementPlaceholder(icon: "exclamationmark.triangle", title: "Connection failed",
                description: device.message ?? "TinyTouch could not connect to this device.",
                actionTitle: "Retry", action: { app.refresh() })
        } else if let status = device.status {
            content(device, status)
        } else {
            VStack(spacing: 12) {
                ProgressView()
                Text("Reading device status…").foregroundStyle(.secondary)
            }.frame(maxWidth: .infinity).padding(.vertical, 60)
        }
    } else {
        RequirementPlaceholder(icon: "cable.connector", title: "Connect tinyTouch with a USB data cable",
            description: "A USB data connection is required to use this feature.")
    }
}

private struct OverviewView: View {
    @EnvironmentObject private var app: AppState
    var body: some View {
        Page(title: "Overview", icon: "dot.radiowaves.left.and.right") {
            availableDevice(app) { device, status in
                Grid(alignment: .leading, horizontalSpacing: 28, verticalSpacing: 12) {
                    row("Connection", device.connection.rawValue.capitalized)
                    row("Firmware", status.firmwareVersion)
                    row("Protocol", String(status.protocol))
                    row("Mode", status.mode.uppercased())
                    row("Sensor", status.sensorReady ? "Ready" : status.sensor)
                    row("Fingerprints", status.fingerprints)
                    row("HID computers", String(status.hidHosts))
                }
                if status.mode == "piv" {
                    Label("PIV mode is active. This release reports PIV status only; provisioning is deferred.", systemImage: "info.circle")
                        .foregroundStyle(.secondary)
                }
                DeviceMessageView()
            }
        }
    }
    private func row(_ label: String, _ value: String) -> some View {
        GridRow { Text(label).foregroundStyle(.secondary); Text(value).textSelection(.enabled) }
    }
}

private struct HIDSetupView: View {
    @EnvironmentObject private var app: AppState
    @State private var password = ""
    @State private var confirmation = ""
    @State private var enroll = true
    @State private var editing = false
    var body: some View {
        Page(title: "HID Setup", icon: "keyboard") {
            availableDevice(app) { device, status in
                if status.mode != "hid" {
                    RequirementPlaceholder(icon: "arrow.triangle.2.circlepath", title: "Switch tinyTouch to HID mode",
                        description: "Use the supported external provisioning tool to switch modes, then reconnect tinyTouch.")
                } else if !status.sensorReady {
                    RequirementPlaceholder(icon: "touchid", title: "Fingerprint sensor unavailable",
                        description: "The fingerprint sensor must be working before HID can be set up.")
                } else if device.connection == .ready && !editing {
                    RequirementPlaceholder(icon: "checkmark.circle", title: "HID is ready",
                        description: "This Mac has HID credentials for tinyTouch.",
                        actionTitle: "Update Credentials", action: { editing = true })
                } else {
                    setupForm(fourViews: status.dialect == .protocol6)
                }
            }
        }
    }

    private func setupForm(fourViews: Bool) -> some View {
        Group {
            Text("After a fingerprint match, tinyTouch securely asks this Mac to type the password stored in your login Keychain.").foregroundStyle(.secondary)
            SecureField("Mac account password", text: $password).frame(maxWidth: 380)
            SecureField("Confirm password", text: $confirmation).frame(maxWidth: 380)
            Toggle(fourViews ? "Enroll four fingerprint views if none exist" : "Enroll fingerprint in slot 1 if none exists",
                   isOn: $enroll)
            Button("Set Up HID") {
                app.configureHID(password: password, confirmation: confirmation, enroll: enroll)
                password = ""; confirmation = ""
            }.buttonStyle(.borderedProminent)
                .disabled(app.busy || password.isEmpty || password != confirmation)
            DeviceMessageView()
        }
    }
}

private struct FingerprintsView: View {
    @EnvironmentObject private var app: AppState
    @State private var deletion: Deletion?
    private var count: Int? { app.selectedDevice?.status?.fingerprintCount.map { min(max($0, 0), 5) } }
    enum Deletion: Identifiable {
        case fingerprint(Int), all
        var id: String {
            switch self { case .fingerprint(let number): "fingerprint-\(number)"; case .all: "all" }
        }
    }
    var body: some View {
        Page(title: "Fingerprints", icon: "touchid") {
            availableDevice(app) { _, status in
                if !status.sensorReady {
                    RequirementPlaceholder(icon: "touchid", title: "Fingerprint sensor unavailable",
                        description: "The fingerprint sensor must be working to manage fingerprints.")
                } else {
                    Text("Configuration changes require an enrolled fingerprint when the device is already secured.").foregroundStyle(.secondary)
                    if let count {
                        Text("Device reports \(count) enrolled fingerprint\(count == 1 ? "" : "s").").foregroundStyle(.secondary)
                    }
                    if let count, count > 0 {
                        VStack(spacing: 0) {
                            ForEach(1...count, id: \.self) { number in
                                HStack {
                                    Label("Fingerprint \(number)", systemImage: "touchid")
                                    Spacer()
                                    Button("Delete", role: .destructive) { deletion = .fingerprint(number) }
                                }.padding(.vertical, 10)
                                if number < count { Divider() }
                            }
                        }.disabled(app.busy)
                    }
                    if let count, count < 5 {
                        Button("Add Fingerprint") { app.enroll(slot: count + 1) }
                            .disabled(app.busy)
                    }
                    if let count, count > 0 {
                        Button("Delete All Fingerprints", role: .destructive) { deletion = .all }
                            .disabled(app.busy)
                    }
                    DeviceMessageView()
                }
            }
        }.alert("Delete fingerprints?", isPresented: Binding(get: { deletion != nil }, set: { if !$0 { deletion = nil } })) {
            Button("Cancel", role: .cancel) { deletion = nil }
            Button("Delete", role: .destructive) {
                let target = deletion; deletion = nil
                switch target { case .fingerprint(let number): app.deleteFingerprint(slot: number); case .all: app.deleteAllFingerprints(); case nil: break }
            }
        } message: {
            switch deletion {
            case .fingerprint(let number): Text("This removes Fingerprint \(number).")
            case .all: Text("This removes every enrolled fingerprint.")
            case nil: EmptyView()
            }
        }
    }
}

private struct ComputersView: View {
    @EnvironmentObject private var app: AppState
    @State private var removeID: String?
    let goToSetup: () -> Void
    var body: some View {
        Page(title: "Computers", icon: "desktopcomputer") {
            availableDevice(app) { device, status in
                if status.mode != "hid" {
                    RequirementPlaceholder(icon: "arrow.triangle.2.circlepath", title: "Switch tinyTouch to HID mode",
                        description: "Use the supported external provisioning tool to switch modes, then reconnect tinyTouch.")
                } else if !status.sensorReady {
                    RequirementPlaceholder(icon: "touchid", title: "Fingerprint sensor unavailable",
                        description: "The fingerprint sensor must be working to manage HID computers.")
                } else if status.protocolVersion < 2 {
                    RequirementPlaceholder(icon: "desktopcomputer", title: "Multiple computers are not supported",
                        description: "This firmware uses protocol 1 and supports only one HID computer. Update firmware outside TinyTouch to use this page.")
                } else if device.connection != .ready {
                    RequirementPlaceholder(icon: "keyboard", title: "Complete HID Setup first",
                        description: "This Mac needs HID credentials before it can manage trusted computers.",
                        actionTitle: "Go to HID Setup", action: goToSetup)
                } else {
                    Text(device.hostCapacity > 0
                        ? "This device can trust up to \(device.hostCapacity) Macs independently."
                        : "This device can trust multiple Macs independently.").foregroundStyle(.secondary)
                    ForEach(device.hostIDs, id: \.self) { id in
                        HStack {
                            Image(systemName: id == device.currentMacID ? "laptopcomputer.and.checkmark" : "desktopcomputer")
                            Text(id).font(.system(.body, design: .monospaced))
                            if id == device.currentMacID { Text("This Mac").foregroundStyle(.secondary) }
                            Spacer(); Button("Remove", role: .destructive) { removeID = id }
                        }
                    }
                    if device.hostIDs.isEmpty { Text("No HID computers reported.").foregroundStyle(.secondary) }
                    HStack {
                        Button("Refresh") { app.refreshComputers() }.disabled(app.busy)
                        if device.currentMacID.map(device.hostIDs.contains) == true {
                            Label("This Mac is trusted", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                        } else if device.hostCapacity > 0 && device.hostIDs.count >= device.hostCapacity {
                            Label("The HID computer list is full", systemImage: "exclamationmark.circle").foregroundStyle(.secondary)
                        } else {
                            Button("Add This Mac") { app.addCurrentMac() }.buttonStyle(.borderedProminent).disabled(app.busy)
                        }
                    }
                    DeviceMessageView()
                }
            }
        }.confirmationDialog("Remove this HID computer?", isPresented: Binding(get: { removeID != nil }, set: { if !$0 { removeID = nil } })) {
            Button("Remove", role: .destructive) { if let id = removeID { app.removeComputer(id: id) }; removeID = nil }
        }
    }
}

private struct SettingsView: View {
    @EnvironmentObject private var app: AppState
    var body: some View {
        Page(title: "Settings", icon: "gear") {
            Toggle("Enable HID background service", isOn: Binding(get: { app.backgroundEnabled }, set: { app.setBackgroundEnabled($0) }))
            Toggle("Launch at login", isOn: Binding(get: { app.launchAtLogin }, set: { app.setLaunchAtLogin($0) }))
            Picker("Keyboard mapping", selection: Binding(get: { app.keyboardMode }, set: { app.setKeyboardMode($0) })) {
                ForEach(KeyboardMode.allCases) { Text($0.title).tag($0) }
            }.frame(maxWidth: 360).disabled(app.selectedDevice == nil)
            if app.legacyHelperDetected {
                ForEach(app.legacyOwners) { Text($0.detail).font(.system(.caption, design: .monospaced)).textSelection(.enabled) }
                Button("Replace Legacy Helper") { app.replaceLegacyHelper() }.buttonStyle(.borderedProminent)
            }
            Text("Passwords and pairing keys are stored only in your macOS Keychain. Replay state remains in ~/Library/Application Support/tinyTouch.").foregroundStyle(.secondary)
            Button("Export Diagnostics…") { app.exportDiagnostics() }
            AppMessageView()
        }
    }
}

private struct OnboardingView: View {
    @EnvironmentObject private var app: AppState
    @State private var launchAtLogin = true
    @State private var replaceLegacy = true
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Image("TinyTouchIcon")
                .resizable().scaledToFit()
                .frame(width: 82, height: 82)
                .shadow(color: .black.opacity(0.22), radius: 18, y: 8)
            Text("Welcome to TinyTouch").font(.largeTitle.bold())
            Text("TinyTouch runs in the menu bar and serves authenticated HID password requests while your device is connected.").foregroundStyle(.secondary)
            Toggle("Launch TinyTouch at login", isOn: $launchAtLogin)
            if app.legacyHelperDetected {
                Toggle("Replace the legacy Python helper", isOn: $replaceLegacy)
                ForEach(app.legacyOwners) { Text($0.detail).font(.system(.caption, design: .monospaced)).textSelection(.enabled) }
                Text("Keychain credentials and replay state will be preserved.").foregroundStyle(.secondary)
            }
            Button("Continue") { app.completeOnboarding(launchAtLogin: launchAtLogin, replaceLegacy: replaceLegacy) }
                .buttonStyle(.borderedProminent)
            AppMessageView()
        }.padding(48).frame(maxWidth: 620, alignment: .leading)
    }
}

private struct LiquidBackdrop: View {
    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Color.accentColor.opacity(0.16), .clear, Color.purple.opacity(0.1)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            Circle().fill(Color.cyan.opacity(0.12)).frame(width: 380).blur(radius: 70).offset(x: 240, y: -190)
            Circle().fill(Color.purple.opacity(0.11)).frame(width: 320).blur(radius: 80).offset(x: -260, y: 210)
        }
        .ignoresSafeArea().accessibilityHidden(true)
    }
}
