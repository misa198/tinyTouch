import SwiftUI

struct SetupWizardView: View {
    @EnvironmentObject private var app: AppState
    let setup: DeviceSetupState
    @State private var mode: SetupMode?
    @State private var password = ""
    @State private var confirmation = ""
    var body: some View {
        ScrollView {
            VStack(spacing: 28) {
                Image("TinyTouchIcon").resizable().scaledToFit().frame(width: 72, height: 72).shadow(color: .black.opacity(0.18), radius: 14, y: 6)
                VStack(spacing: 6) {
                    Text(title).font(.largeTitle.bold()); Text(setup.deviceName).font(.headline)
                    Text(mode == .hid && setup.phase == .chooseMode ? "Enter the password tinyTouch should type after authentication." : setup.message).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }
                if setup.phase == .chooseMode {
                    InformationDialog(title: "Fingerprint required",
                                      message: "Fingerprint enrollment is required for both HID and PIV. Keep a finger ready before continuing.",
                                      icon: "touchid")
                }
                if setup.phase == .chooseMode { modePicker } else if setup.phase == .complete { completion } else { progress }
            }.padding(48).frame(maxWidth: 680).frame(maxWidth: .infinity).animation(.easeInOut(duration: 0.25), value: mode)
        }
    }
    private var title: String { setup.phase == .complete ? "Setup Complete" : setup.phase == .chooseMode ? (mode == .hid ? "Set Up HID" : "Set Up tinyTouch") : "Setting Up tinyTouch" }
    @ViewBuilder private var modePicker: some View { if mode == .hid { passwordForm.transition(.move(edge: .trailing).combined(with: .opacity)) } else { modeSelection.transition(.move(edge: .leading).combined(with: .opacity)) } }
    private var modeSelection: some View {
        VStack(spacing: 18) {
            HStack(spacing: 16) { modeCard(.hid, icon: "keyboard", title: "HID", detail: "Type your password after a fingerprint match."); modeCard(.piv, icon: "person.text.rectangle", title: "PIV", detail: "Use tinyTouch as a macOS smart card.") }
            if let error = setup.error { Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red) }
            Button("Continue") { guard let mode else { return }; app.startSetup(mode: mode, password: password, confirmation: confirmation) }.buttonStyle(.borderedProminent).disabled(mode == nil || app.busy)
        }
    }
    private var passwordForm: some View {
        VStack(spacing: 18) {
            SecureField("Mac account password", text: $password).frame(maxWidth: 380); SecureField("Confirm password", text: $confirmation).frame(maxWidth: 380)
            if !confirmation.isEmpty && password != confirmation { Label("Passwords do not match.", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red) }
            Text("Maximum 160 UTF-8 bytes. Your current keyboard mapping must support every character.").font(.caption).foregroundStyle(.secondary)
            if let error = setup.error { Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red) }
            HStack { Button("Back") { mode = nil; password = ""; confirmation = "" }; Button("Continue") { app.startSetup(mode: .hid, password: password, confirmation: confirmation) }.buttonStyle(.borderedProminent).disabled(password.isEmpty || password != confirmation || app.busy) }
        }
    }
    private func modeCard(_ value: SetupMode, icon: String, title: String, detail: String) -> some View {
        Button { mode = value } label: {
            VStack(spacing: 10) { Image(systemName: icon).font(.system(size: 34)); Text(title).font(.title2.bold()); Text(detail).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center) }
                .padding(20).frame(maxWidth: .infinity, minHeight: 150).background(mode == value ? Color.accentColor.opacity(0.18) : Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 18, style: .continuous)).overlay(RoundedRectangle(cornerRadius: 18).stroke(mode == value ? Color.accentColor : .clear, lineWidth: 2))
        }.buttonStyle(.plain).accessibilityLabel("\(title): \(detail)")
    }
    private var progress: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(Array(steps.enumerated()), id: \.element.0) { index, step in
                let current = steps.firstIndex(where: { $0.0 == setup.phase }) ?? 0
                Label(step.1, systemImage: setup.phase == .complete || index < current ? "checkmark.circle.fill" : index == current && setup.error != nil ? "exclamationmark.circle.fill" : index == current ? "circle.inset.filled" : "circle").foregroundStyle(index <= current ? Color.primary : Color.secondary)
            }
            if let error = setup.error {
                Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red).padding(.top, 8)
                HStack { Button("Retry") { app.retrySetup() }.buttonStyle(.borderedProminent).disabled(app.busy); Button("Start Over") { mode = nil; password = ""; confirmation = ""; app.startOverSetup() }.disabled(app.busy); if setup.canSkipPairing { Button("Skip Pairing") { app.skipPIVPairing() }.disabled(app.busy) } }
            } else { ProgressView().padding(.top, 8) }
        }.frame(maxWidth: 480, alignment: .leading)
    }
    private var steps: [(DeviceSetupPhase, String)] { var values: [(DeviceSetupPhase, String)] = [(.authenticate, "Authorize setup")]; if setup.mode == .hid { values += [(.registerMac, "Register this Mac"), (.switchMode, "Enable HID mode")] } else { values += [(.createIdentity, "Create PIV identity")] }; values += [(.enroll, "Enroll fingerprint"), (.verify, "Verify setup")]; if setup.mode == .piv { values += [(.pair, "Pair with macOS")] }; return values }
    private var completion: some View { VStack(spacing: 18) { Label("\(setup.mode?.rawValue.uppercased() ?? "tinyTouch") configured", systemImage: "checkmark.seal.fill").font(.title2.bold()).foregroundStyle(.green); Text("Your fingerprint is enrolled. You can add more later.").foregroundStyle(.secondary); Button("Done") { app.finishSetup() }.buttonStyle(.borderedProminent) } }
}

struct OnboardingView: View {
    @EnvironmentObject private var app: AppState
    let flashBlankBoard: () -> Void
    @State private var launchAtLogin = true
    @State private var replaceLegacy = true
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Image("TinyTouchIcon").resizable().scaledToFit().frame(width: 82, height: 82).shadow(color: .black.opacity(0.22), radius: 18, y: 8)
            Text("Welcome to TinyTouch").font(.largeTitle.bold())
            Text("TinyTouch runs in the menu bar and serves authenticated HID password requests while your device is connected.").foregroundStyle(.secondary)
            Toggle("Launch TinyTouch at login", isOn: $launchAtLogin)
            if app.legacyHelperDetected { Toggle("Replace the legacy Python helper", isOn: $replaceLegacy); ForEach(app.legacyOwners) { Text($0.detail).font(.system(.caption, design: .monospaced)).textSelection(.enabled) }; Text("Keychain credentials and replay state will be preserved.").foregroundStyle(.secondary) }
            Button("Continue") { app.completeOnboarding(launchAtLogin: launchAtLogin, replaceLegacy: replaceLegacy) }.buttonStyle(.borderedProminent)
            Button("Flash a Blank Board") { flashBlankBoard() }
            Text("Use this when tinyTouch has no working firmware. The app will open Firmware and detect an ESP32-S3 in ROM/download mode.").font(.caption).foregroundStyle(.secondary)
            AppMessageView()
        }.padding(48).frame(maxWidth: 620, alignment: .leading)
    }
}
