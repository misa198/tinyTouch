import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var app: AppState
    @State private var section = Section.overview
    @State private var showMainUI = false
    enum Section: String, CaseIterable, Identifiable {
        case overview = "Overview", setup = "HID Setup", fingerprints = "Fingerprints", computers = "Computers", firmware = "Firmware", settings = "Settings"
        var id: Self { self }
        var icon: String {
            switch self {
            case .overview: "dot.radiowaves.left.and.right"
            case .setup: "keyboard"
            case .fingerprints: "touchid"
            case .computers: "desktopcomputer"
            case .firmware: "arrow.down.circle"
            case .settings: "gear"
            }
        }
    }
    var body: some View {
        ZStack {
            LiquidBackdrop()
            if app.showFlashOnboarding { NewBoardFlashView() }
            else if let setup = app.setup { SetupWizardView(setup: setup) }
            else if !app.onboardingComplete && !showMainUI {
                OnboardingView { section = .firmware; showMainUI = true }
            } else {
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
            if let prompt = app.fingerprintPrompt { FingerprintPromptView(message: prompt.message) }
        }.frame(minWidth: 720, minHeight: 600)
            .animation(.easeInOut(duration: 0.15), value: app.fingerprintPrompt)
    }
    @ViewBuilder private var detail: some View {
        switch section {
        case .overview: OverviewView()
        case .setup: HIDSetupView()
        case .fingerprints: FingerprintsView()
        case .computers: ComputersView { section = .setup }
        case .firmware: FirmwareView()
        case .settings: SettingsView()
        }
    }
}

private struct FirmwareView: View {
    @EnvironmentObject private var app: AppState
    @State private var confirming = false

    var body: some View {
        Page(title: "Firmware", icon: "arrow.down.circle") { firmwareControls }
        .alert(app.firmware.strategy == .ota ? "Install firmware update?" : "Factory flash selected device?", isPresented: $confirming) {
            Button("Cancel", role: .cancel) {}
            Button(app.firmware.strategy == .ota ? "Download and Install" : "Download and Factory Flash",
                   role: app.firmware.strategy == .factory ? .destructive : nil) { app.installFirmware() }
        } message: {
            Text(app.firmware.strategy == .ota
                ? "The verified image will be downloaded and written to the inactive OTA slot. Device data is preserved."
                : "The verified merged image will be written at 0x0. Fingerprints, keys, hosts, and settings will be reset. Confirm this serial adapter is connected to tinyTouch.")
        }
    }

    @ViewBuilder private var firmwareControls: some View {
        VStack(alignment: .leading, spacing: 18) {
            Toggle("Show CP210x/CH340 serial adapters (Advanced)", isOn: Binding(
                get: { app.advancedFirmwareDevices }, set: { app.setAdvancedFirmwareDevices($0) }
            )).disabled(app.isFirmwareWriting)
            if let device = app.selectedDevice {
                Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 10) {
                    GridRow { Text("Target").foregroundStyle(.secondary); Text(device.name) }
                    GridRow { Text("Current").foregroundStyle(.secondary); Text(app.firmware.current) }
                    GridRow { Text("Latest").foregroundStyle(.secondary); Text(app.firmware.latest) }
                    GridRow { Text("Strategy").foregroundStyle(.secondary); Text(app.firmware.strategy?.rawValue ?? "Not checked") }
                }
                Text(app.firmware.message).foregroundStyle(.secondary)
                if [.downloading, .writing].contains(app.firmware.phase) {
                    ProgressView(value: app.firmware.progress).frame(maxWidth: 420)
                }
                if let error = app.firmware.error {
                    Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red).textSelection(.enabled)
                }
                HStack {
                    if app.firmware.phase == .ready {
                        Button(app.firmware.strategy == .ota ? "Install Update…" : "Factory Flash…") { confirming = true }
                            .buttonStyle(.borderedProminent).disabled(app.busy)
                    } else if app.firmware.needsManualBoot {
                        Button("Retry After BOOT + RESET") { app.retryManualFactoryFlash() }
                            .buttonStyle(.borderedProminent).disabled(app.busy)
                    } else if ![.downloading, .writing, .reconnect].contains(app.firmware.phase) {
                        Button(app.firmware.phase == .failed ? "Retry" : "Check for Updates") { app.checkFirmware() }
                            .buttonStyle(.borderedProminent).disabled(app.busy)
                    }
                }
            } else {
                RequirementPlaceholder(icon: "cable.connector", title: "Connect tinyTouch or an ESP32-S3 in ROM mode",
                    description: "Runtime and native Espressif USB ports appear automatically. Enable Advanced only for a confirmed tinyTouch on CP210x/CH340.")
            }
        }
    }
}

private struct NewBoardFlashView: View {
    @EnvironmentObject private var app: AppState

    var body: some View {
        ScrollView {
            VStack(spacing: 28) {
                Image("TinyTouchIcon").resizable().scaledToFit().frame(width: 72, height: 72)
                    .shadow(color: .black.opacity(0.18), radius: 14, y: 6)
                VStack(spacing: 6) {
                    Text(title).font(.largeTitle.bold())
                    Text(detail).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }
                VStack(alignment: .leading, spacing: 14) {
                    step("1", "Board ready", complete: true, active: false)
                    step("2", "Fetch verified firmware", complete: hasFetchedFirmware, active: app.firmware.phase == .checking || app.firmware.phase == .downloading)
                    step("3", "Flash and restart", complete: app.firmware.phase == .complete, active: [.writing, .reconnect].contains(app.firmware.phase))
                }
                .frame(maxWidth: 420, alignment: .leading)
                if [.downloading, .writing].contains(app.firmware.phase) { ProgressView(value: app.firmware.progress).frame(maxWidth: 420) }
                if let error = app.firmware.error { Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red).textSelection(.enabled) }
                if app.firmware.phase == .complete {
                    Button("Set Up tinyTouch") { app.finishNewBoardFlash() }.buttonStyle(.borderedProminent)
                } else if app.firmware.needsManualBoot {
                    Button("Retry After BOOT + RESET") { app.retryManualFactoryFlash() }.buttonStyle(.borderedProminent).disabled(app.busy)
                } else {
                    Button(app.firmware.phase == .failed ? "Try Again" : "Download & Flash") { app.flashNewBoard() }
                        .buttonStyle(.borderedProminent).disabled(app.busy)
                }
            }
            .padding(48).frame(maxWidth: 680).frame(maxWidth: .infinity)
        }
    }

    private var hasFetchedFirmware: Bool { [.downloading, .writing, .reconnect, .complete].contains(app.firmware.phase) }
    private var title: String { app.firmware.phase == .complete ? "Board Ready" : "Flash a New Board" }
    private var detail: String { app.firmware.phase == .complete ? "Firmware is installed. Continue to set up tinyTouch." : app.firmware.message }
    private func step(_ number: String, _ label: String, complete: Bool, active: Bool) -> some View {
        Label(label, systemImage: complete ? "checkmark.circle.fill" : active ? "arrow.triangle.2.circlepath.circle.fill" : "circle")
            .foregroundStyle(complete ? .green : active ? .primary : .secondary)
            .fontWeight(active ? .semibold : .regular)
            .accessibilityLabel("Step \(number): \(label)")
    }
}

private struct SetupWizardView: View {
    @EnvironmentObject private var app: AppState
    let setup: DeviceSetupState
    @State private var mode: SetupMode?
    @State private var password = ""
    @State private var confirmation = ""

    var body: some View {
        ScrollView {
            VStack(spacing: 28) {
                Image("TinyTouchIcon")
                    .resizable().scaledToFit().frame(width: 72, height: 72)
                    .shadow(color: .black.opacity(0.18), radius: 14, y: 6)
                VStack(spacing: 6) {
                    Text(title).font(.largeTitle.bold())
                    Text(setup.deviceName).font(.headline)
                    Text(mode == .hid && setup.phase == .chooseMode ? "Enter the password tinyTouch should type after authentication." : setup.message)
                        .foregroundStyle(.secondary).multilineTextAlignment(.center)
                }
                if setup.phase == .chooseMode { modePicker }
                else if setup.phase == .complete { completion }
                else { progress }
            }
            .padding(48).frame(maxWidth: 680).frame(maxWidth: .infinity)
            .animation(.easeInOut(duration: 0.25), value: mode)
        }
    }

    private var title: String {
        setup.phase == .complete ? "Setup Complete" :
            setup.phase == .chooseMode ? (mode == .hid ? "Set Up HID" : "Set Up tinyTouch") : "Setting Up tinyTouch"
    }

    @ViewBuilder private var modePicker: some View {
        if mode == .hid {
            passwordForm.transition(.move(edge: .trailing).combined(with: .opacity))
        } else {
            modeSelection.transition(.move(edge: .leading).combined(with: .opacity))
        }
    }

    private var modeSelection: some View {
        VStack(spacing: 18) {
            HStack(spacing: 16) {
                modeCard(.hid, icon: "keyboard", title: "HID", detail: "Type your password after a fingerprint match.")
                modeCard(.piv, icon: "person.text.rectangle", title: "PIV", detail: "Use tinyTouch as a macOS smart card.")
            }
            if let error = setup.error { Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red) }
            Button("Continue") {
                guard let mode else { return }
                app.startSetup(mode: mode, password: password, confirmation: confirmation)
            }
            .buttonStyle(.borderedProminent).disabled(mode == nil || app.busy)
        }
    }

    private var passwordForm: some View {
        VStack(spacing: 18) {
            SecureField("Mac account password", text: $password).frame(maxWidth: 380)
            SecureField("Confirm password", text: $confirmation).frame(maxWidth: 380)
            if !confirmation.isEmpty && password != confirmation {
                Label("Passwords do not match.", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
            }
            Text("Maximum 160 UTF-8 bytes. Your current keyboard mapping must support every character.")
                .font(.caption).foregroundStyle(.secondary)
            if let error = setup.error { Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red) }
            HStack {
                Button("Back") { mode = nil; password = ""; confirmation = "" }
                Button("Continue") { app.startSetup(mode: .hid, password: password, confirmation: confirmation) }
                    .buttonStyle(.borderedProminent).disabled(password.isEmpty || password != confirmation || app.busy)
            }
        }
    }

    private func modeCard(_ value: SetupMode, icon: String, title: String, detail: String) -> some View {
        Button { mode = value } label: {
            VStack(spacing: 10) {
                Image(systemName: icon).font(.system(size: 34))
                Text(title).font(.title2.bold())
                Text(detail).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
            .padding(20).frame(maxWidth: .infinity, minHeight: 150)
            .background(mode == value ? Color.accentColor.opacity(0.18) : Color.primary.opacity(0.05),
                        in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 18).stroke(mode == value ? Color.accentColor : .clear, lineWidth: 2))
        }.buttonStyle(.plain).accessibilityLabel("\(title): \(detail)")
    }

    private var progress: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(Array(steps.enumerated()), id: \.element.0) { index, step in
                let current = steps.firstIndex(where: { $0.0 == setup.phase }) ?? 0
                Label(step.1, systemImage: setup.phase == .complete || index < current ? "checkmark.circle.fill" :
                      index == current && setup.error != nil ? "exclamationmark.circle.fill" :
                      index == current ? "circle.inset.filled" : "circle")
                    .foregroundStyle(index <= current ? Color.primary : Color.secondary)
            }
            if let error = setup.error {
                Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red).padding(.top, 8)
                HStack {
                    Button("Retry") { app.retrySetup() }.buttonStyle(.borderedProminent).disabled(app.busy)
                    Button("Start Over") {
                        mode = nil; password = ""; confirmation = ""; app.startOverSetup()
                    }.disabled(app.busy)
                    if setup.canSkipPairing { Button("Skip Pairing") { app.skipPIVPairing() }.disabled(app.busy) }
                }
            } else { ProgressView().padding(.top, 8) }
        }.frame(maxWidth: 480, alignment: .leading)
    }

    private var steps: [(DeviceSetupPhase, String)] {
        var values: [(DeviceSetupPhase, String)] = [(.authenticate, "Authorize setup")]
        if setup.mode == .hid { values += [(.registerMac, "Register this Mac"), (.switchMode, "Enable HID mode")] }
        else { values += [(.createIdentity, "Create PIV identity")] }
        values += [(.enroll, "Enroll fingerprint"), (.verify, "Verify setup")]
        if setup.mode == .piv { values += [(.pair, "Pair with macOS")] }
        return values
    }

    private var completion: some View {
        VStack(spacing: 18) {
            Label("\(setup.mode?.rawValue.uppercased() ?? "tinyTouch") configured", systemImage: "checkmark.seal.fill")
                .font(.title2.bold()).foregroundStyle(.green)
            Text("Your fingerprint is enrolled. You can add more later.").foregroundStyle(.secondary)
            Button("Done") { app.finishSetup() }.buttonStyle(.borderedProminent)
        }
    }
}

private struct FingerprintPromptView: View {
    let message: String
    var body: some View {
        ZStack {
            Color.black.opacity(0.3).ignoresSafeArea()
            VStack(spacing: 16) {
                Image(systemName: "touchid").font(.system(size: 42)).foregroundStyle(.tint)
                Text("Fingerprint Required").font(.title2.bold())
                Text(message).foregroundStyle(.secondary)
                ProgressView()
            }
            .padding(28).frame(minWidth: 320)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .shadow(radius: 24)
        }
        .transition(.opacity)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isModal)
    }
}

private struct DevicePicker: View {
    @EnvironmentObject private var app: AppState
    var body: some View {
        HStack(spacing: 12) {
            if app.devices.count > 1 {
                Picker("Device", selection: $app.selectedID) {
                    ForEach(app.devices) { Text($0.name).tag(Optional($0.id)) }
                }.frame(maxWidth: 360).disabled(app.busy)
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
                    Label(status.fields["piv"] == "ready" ? "PIV identity is ready." : "PIV identity is not configured.", systemImage: "info.circle")
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
    @State private var confirmingFactoryReset = false
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
            Divider()
            Text("Factory Reset").font(.headline)
            Text("Erase fingerprints, PIV keys, trusted computers, device settings, and this Mac's credentials for the selected tinyTouch.")
                .foregroundStyle(.secondary)
            Button("Factory Reset", role: .destructive) { confirmingFactoryReset = true }
                .disabled(app.busy || !app.backgroundEnabled || app.selectedDevice?.connection == .error ||
                          app.selectedDevice?.status?.protocolVersion != 6 ||
                          app.selectedDevice?.status?.sensorReady != true)
            if let status = app.selectedDevice?.status, status.protocolVersion != 6 {
                Text("Update this device to protocol 6 firmware to use Factory Reset.").foregroundStyle(.secondary)
            } else if app.selectedDevice?.status?.sensorReady == false {
                Text("The fingerprint sensor must be available so its templates can be erased.").foregroundStyle(.secondary)
            }
            AppMessageView()
        }
        .alert("Factory reset selected tinyTouch?", isPresented: $confirmingFactoryReset) {
            Button("Cancel", role: .cancel) {}
            Button("Factory Reset", role: .destructive) { app.factoryReset() }
        } message: {
            Text("This permanently erases every fingerprint, PIV key, trusted computer, and device setting. TinyTouch will return to its unconfigured PIV state. Matching credentials and settings on this Mac will also be deleted.")
        }
    }
}

private struct OnboardingView: View {
    @EnvironmentObject private var app: AppState
    let flashBlankBoard: () -> Void
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
            Button("Flash a Blank Board") { flashBlankBoard() }
            Text("Use this when tinyTouch has no working firmware. The app will open Firmware and detect an ESP32-S3 in ROM/download mode.")
                .font(.caption).foregroundStyle(.secondary)
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
