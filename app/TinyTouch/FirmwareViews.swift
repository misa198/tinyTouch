import SwiftUI

struct FirmwareView: View {
    @EnvironmentObject private var app: AppState
    @State private var confirming = false

    var body: some View {
        Page(title: "Firmware", icon: "arrow.down.circle") { firmwareControls }
        .alert(app.firmware.strategy == .ota ? "Install firmware update?" : "Factory flash selected device?", isPresented: $confirming) {
            Button("Cancel", role: .cancel) {}
            Button(app.firmware.strategy == .ota ? "Download and Install" : "Download and Factory Flash", role: app.firmware.strategy == .factory ? .destructive : nil) { app.installFirmware() }
        } message: {
            Text(app.firmware.strategy == .ota ? "The verified image will be downloaded and written to the inactive OTA slot. Device data is preserved." : "The verified merged image will be written at 0x0. Fingerprints, keys, hosts, and settings will be reset. Confirm this serial adapter is connected to tinyTouch.")
        }
    }

    @ViewBuilder private var firmwareControls: some View {
        VStack(alignment: .leading, spacing: 18) {
            Toggle("Show CP210x/CH340 serial adapters (Advanced)", isOn: Binding(get: { app.advancedFirmwareDevices }, set: { app.setAdvancedFirmwareDevices($0) })).disabled(app.isFirmwareWriting)
            if let device = app.selectedDevice {
                Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 10) {
                    GridRow { Text("Target").foregroundStyle(.secondary); Text(device.name) }
                    GridRow { Text("Current").foregroundStyle(.secondary); Text(device.status?.firmwareVersion ?? (device.identity.kind == .rom ? "ROM mode" : "Unknown")) }
                    GridRow { Text("Latest").foregroundStyle(.secondary); Text(app.firmware.latest) }
                    GridRow { Text("Strategy").foregroundStyle(.secondary); Text(app.firmware.strategy?.rawValue ?? "Not checked") }
                }
                Text(app.firmware.message).foregroundStyle(.secondary)
                if [.downloading, .writing].contains(app.firmware.phase) { ProgressView(value: app.firmware.progress).frame(maxWidth: 420) }
                if let error = app.firmware.error { Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red).textSelection(.enabled) }
                HStack {
                    if app.firmware.phase == .ready { Button(app.firmware.strategy == .ota ? "Install Update…" : "Factory Flash…") { confirming = true }.buttonStyle(.borderedProminent).disabled(app.busy) }
                    else if app.firmware.needsManualBoot { Button("Retry After BOOT + RESET") { app.retryManualFactoryFlash() }.buttonStyle(.borderedProminent).disabled(app.busy) }
                    else if ![.downloading, .writing, .reconnect].contains(app.firmware.phase) { Button(app.firmware.phase == .failed ? "Retry" : "Check for Updates") { app.checkFirmware() }.buttonStyle(.borderedProminent).disabled(app.busy) }
                }
            } else {
                RequirementPlaceholder(icon: "cable.connector", title: "Connect tinyTouch or an ESP32-S3 in ROM mode", description: "Runtime and native Espressif USB ports appear automatically. Enable Advanced only for a confirmed tinyTouch on CP210x/CH340.")
            }
        }
    }
}

struct NewBoardFlashView: View {
    @EnvironmentObject private var app: AppState

    var body: some View {
        ScrollView {
            VStack(spacing: 28) {
                Image("TinyTouchIcon").resizable().scaledToFit().frame(width: 72, height: 72).shadow(color: .black.opacity(0.18), radius: 14, y: 6)
                VStack(spacing: 6) { Text(title).font(.largeTitle.bold()); Text(detail).foregroundStyle(.secondary).multilineTextAlignment(.center) }
                VStack(alignment: .leading, spacing: 14) {
                    step("1", "Board ready", complete: true, active: false)
                    step("2", "Fetch verified firmware", complete: hasFetchedFirmware, active: app.firmware.phase == .checking || app.firmware.phase == .downloading)
                    step("3", "Connect bootloader and flashing board", complete: hasStartedWriting, active: app.firmware.phase == .writing && app.firmware.progress == 0)
                    step("4", "Restart board", complete: app.firmware.phase == .complete, active: app.firmware.phase == .writing && app.firmware.progress > 0)
                }.frame(maxWidth: 420, alignment: .leading)
                if app.firmware.phase == .checking || ([.downloading, .writing].contains(app.firmware.phase) && app.firmware.progress == 0) { ProgressView().frame(maxWidth: 420) }
                else if [.downloading, .writing].contains(app.firmware.phase) { ProgressView(value: app.firmware.progress).frame(maxWidth: 420) }
                if let error = app.firmware.error { Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red).textSelection(.enabled) }
                if app.firmware.phase == .reconnect { Label("Flash is complete. Unplug tinyTouch, then plug it back in. Setup starts automatically once it reconnects.", systemImage: "cable.connector").foregroundStyle(.secondary).frame(maxWidth: 420, alignment: .leading) }
                else if app.firmware.phase == .complete { ProgressView().frame(maxWidth: 420) }
                else if app.firmware.needsManualBoot { Button("Retry After BOOT + RESET") { app.retryManualFactoryFlash() }.buttonStyle(.borderedProminent).disabled(app.busy) }
                else if app.canRetryNewBoardFactoryReset { Button("Retry Factory Reset") { app.retryNewBoardFactoryReset() }.buttonStyle(.borderedProminent).disabled(app.busy) }
                else { Button(app.firmware.phase == .failed ? "Try Again" : "Download & Flash") { app.flashNewBoard() }.buttonStyle(.borderedProminent).disabled(app.busy) }
            }.padding(48).frame(maxWidth: 680).frame(maxWidth: .infinity)
        }
    }

    private var hasFetchedFirmware: Bool { [.downloading, .writing, .reconnect, .complete].contains(app.firmware.phase) }
    private var hasStartedWriting: Bool { (app.firmware.phase == .writing && app.firmware.progress > 0) || [.reconnect, .complete].contains(app.firmware.phase) }
    private var title: String { app.firmware.phase == .complete ? "Board Ready" : "Flash a New Board" }
    private var detail: String { app.firmware.phase == .complete ? "Firmware is installed. Continue to set up tinyTouch." : app.firmware.message }
    private func step(_ number: String, _ label: String, complete: Bool, active: Bool) -> some View {
        Label(label, systemImage: complete ? "checkmark.circle.fill" : active ? "arrow.triangle.2.circlepath.circle.fill" : "circle").foregroundStyle(complete ? .green : active ? .primary : .secondary).fontWeight(active ? .semibold : .regular).accessibilityLabel("Step \(number): \(label)")
    }
}
