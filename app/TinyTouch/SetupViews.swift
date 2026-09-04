import SwiftUI

struct SetupWizardView: View {
    @EnvironmentObject private var app: AppState
    let setup: DeviceSetupState
    @State private var mode: SetupMode?
    @State private var password = ""
    @State private var confirmation = ""
    init(setup: DeviceSetupState) {
        self.setup = setup
        _mode = State(initialValue: setup.mode)
    }
    var body: some View {
        ScrollView {
            VStack(spacing: 28) {
                Image("TinyTouchIcon").resizable().scaledToFit().frame(width: 72, height: 72).shadow(color: .black.opacity(0.18), radius: 14, y: 6)
                VStack(spacing: 6) {
                    Text(L10n.text(title)).font(.largeTitle.bold()); Text(L10n.text(setup.deviceName)).font(.headline)
                    Text(L10n.text(mode == .hid && setup.phase == .chooseMode ? "enter_password_type_authentication" : setup.message)).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }
                if setup.phase == .chooseMode {
                    InformationDialog(title: "fingerprint_required_title",
                                      message: "fingerprint_enrollment_ready_continuing",
                                      icon: "touchid")
                }
                if setup.phase == .chooseMode { modePicker } else if setup.phase == .complete { completion } else { progress }
            }.padding(48).frame(maxWidth: 680).frame(maxWidth: .infinity).animation(.easeInOut(duration: 0.25), value: mode)
        }
    }
    private var title: String { setup.phase == .complete ? "setup_complete" : setup.phase == .chooseMode ? (mode == .hid ? "set_hid" : "set_tinytouch") : "setting_tinytouch" }
    @ViewBuilder private var modePicker: some View { if mode == .hid { passwordForm.transition(.move(edge: .trailing).combined(with: .opacity)) } else { modeSelection.transition(.move(edge: .leading).combined(with: .opacity)) } }
    private var modeSelection: some View {
        VStack(spacing: 18) {
            HStack(spacing: 16) { modeCard(.hid, icon: "keyboard", title: "HID", detail: "type_password_fingerprint_match"); modeCard(.piv, icon: "person.text.rectangle", title: "PIV", detail: "use_tinytouch_smart_card") }
            if let error = setup.error { Label(L10n.text(error), systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red) }
            Button("common_continue") { guard let mode else { return }; app.startSetup(mode: mode, password: password, confirmation: confirmation) }.buttonStyle(.borderedProminent).disabled(mode == nil || app.busy)
        }
    }
    private var passwordForm: some View {
        VStack(spacing: 18) {
            SecureField("mac_account_password", text: $password).frame(maxWidth: 380); SecureField("confirm_password", text: $confirmation).frame(maxWidth: 380)
            if !confirmation.isEmpty && password != confirmation { Label("passwords_not_match", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red) }
            Text("maximum_160_support_character").font(.caption).foregroundStyle(.secondary)
            if let error = setup.error { Label(L10n.text(error), systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red) }
            HStack { Button("common_back") { mode = nil; password = ""; confirmation = "" }; Button("common_continue") { app.startSetup(mode: .hid, password: password, confirmation: confirmation) }.buttonStyle(.borderedProminent).disabled(password.isEmpty || password != confirmation || app.busy) }
        }
    }
    private func modeCard(_ value: SetupMode, icon: String, title: String, detail: String) -> some View {
        Button { mode = value } label: {
            VStack(spacing: 10) { Image(systemName: icon).font(.system(size: 34)); Text(L10n.text(title)).font(.title2.bold()); Text(L10n.text(detail)).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center) }
                .padding(20).frame(maxWidth: .infinity, minHeight: 150).background(mode == value ? Color.accentColor.opacity(0.18) : Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 18, style: .continuous)).overlay(RoundedRectangle(cornerRadius: 18).stroke(mode == value ? Color.accentColor : .clear, lineWidth: 2))
        }.buttonStyle(.plain).accessibilityLabel(L10n.text("text", L10n.text(title), L10n.text(detail)))
    }
    private var progress: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(Array(steps.enumerated()), id: \.element.0) { index, step in
                let current = steps.firstIndex(where: { $0.0 == setup.phase }) ?? 0
                Label(L10n.text(step.1), systemImage: setup.phase == .complete || index < current ? "checkmark.circle.fill" : index == current && setup.error != nil ? "exclamationmark.circle.fill" : index == current ? "circle.inset.filled" : "circle").foregroundStyle(index <= current ? Color.primary : Color.secondary)
            }
            if setup.phase == .pair && setup.provisioningComplete && setup.error == nil && !setup.pairingStarted {
                InformationDialog(title: "reconnect_tinytouch",
                                  message: "unplug_tinytouch_piv_identity",
                                  icon: "cable.connector")
                HStack { Button("i_reconnected_pair_macos") { app.pairPIV() }.buttonStyle(.borderedProminent).disabled(app.busy); Button("skip_pairing") { app.skipPIVPairing() }.disabled(app.busy) }
            } else if setup.phase == .pair && setup.provisioningComplete && setup.error == nil {
                InformationDialog(title: "finish_pairing_macos",
                                  message: "pin_prompt_pin_automatically",
                                  icon: "lock")
                HStack { Button("i_finished_pairing") { app.confirmPIVPairing() }.buttonStyle(.borderedProminent).disabled(app.busy); Button("skip_pairing") { app.skipPIVPairing() }.disabled(app.busy) }
            } else if let error = setup.error {
                Label(L10n.text(error), systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red).padding(.top, 8)
                HStack { Button("common_retry") { app.retrySetup() }.buttonStyle(.borderedProminent).disabled(app.busy); Button("start_over") { mode = nil; password = ""; confirmation = ""; app.startOverSetup() }.disabled(app.busy); if setup.canSkipPairing { Button("skip_pairing") { app.skipPIVPairing() }.disabled(app.busy) } }
            } else { ProgressView().padding(.top, 8) }
        }.frame(maxWidth: 480, alignment: .leading)
    }
    private var steps: [(DeviceSetupPhase, String)] { var values: [(DeviceSetupPhase, String)] = [(.authenticate, "authorize_setup")]; if setup.mode == .hid { values += [(.registerMac, "register_mac"), (.switchMode, "enable_hid_mode")] } else { values += [(.createIdentity, "create_piv_identity")] }; values += [(.enroll, "enroll_fingerprint"), (.verify, "verify_setup")]; if setup.mode == .piv { values += [(.pair, "pair_macos")] }; return values }
    private var completion: some View { VStack(spacing: 18) { Label(L10n.text("configured", setup.mode?.rawValue.uppercased() ?? "tinyTouch"), systemImage: "checkmark.seal.fill").font(.title2.bold()).foregroundStyle(.green); Text("fingerprint_enrolled_more_later").foregroundStyle(.secondary); Button("common_done") { app.finishSetup() }.buttonStyle(.borderedProminent) } }
}

struct OnboardingView: View {
    @EnvironmentObject private var app: AppState
    let flashBlankBoard: () -> Void
    @State private var launchAtLogin = true
    @State private var replaceLegacy = true
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Image("TinyTouchIcon").resizable().scaledToFit().frame(width: 82, height: 82).shadow(color: .black.opacity(0.22), radius: 18, y: 8)
            Text("welcome_tinytouch").font(.largeTitle.bold())
            Text("tinytouch_runs_device_connected").foregroundStyle(.secondary)
            Toggle("launch_tinytouch_login", isOn: $launchAtLogin)
            if app.legacyHelperDetected { Toggle("replace_legacy_python_helper", isOn: $replaceLegacy); ForEach(app.legacyOwners) { Text($0.detail).font(.system(.caption, design: .monospaced)).textSelection(.enabled) }; Text("keychain_credentials_state_preserved").foregroundStyle(.secondary) }
            Button("common_continue") { app.completeOnboarding(launchAtLogin: launchAtLogin, replaceLegacy: replaceLegacy) }.buttonStyle(.borderedProminent)
            Button("flash_blank_board") { flashBlankBoard() }
            Text("use_tinytouch_download_mode").font(.caption).foregroundStyle(.secondary)
            AppMessageView()
        }.padding(48).frame(maxWidth: 620, alignment: .leading)
    }
}
