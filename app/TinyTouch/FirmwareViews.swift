import SwiftUI

struct FirmwareView: View {
    @EnvironmentObject private var app: AppState
    @State private var confirming = false

    var body: some View {
        Page(title: "nav_firmware", icon: "arrow.down.circle") { firmwareControls }
        .alert(L10n.text(app.firmware.strategy == .ota ? "install_firmware_update" : "factory_flash_selected_device"), isPresented: $confirming) {
            Button("common_cancel", role: .cancel) {}
            Button(L10n.text(app.firmware.strategy == .ota ? "download_install" : "download_factory_flash"), role: app.firmware.strategy == .factory ? .destructive : nil) { app.installFirmware() }
        } message: {
            Text(L10n.text(app.firmware.strategy == .ota ? "verified_image_data_preserved" : "verified_merged_connected_tinytouch"))
        }
    }

    @ViewBuilder private var firmwareControls: some View {
        VStack(alignment: .leading, spacing: 18) {
            Toggle("show_cp210x_adapters_advanced", isOn: Binding(get: { app.advancedFirmwareDevices }, set: { app.setAdvancedFirmwareDevices($0) })).disabled(app.isFirmwareWriting)
            if let device = app.selectedDevice {
                Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 10) {
                    GridRow { Text("firmware_target").foregroundStyle(.secondary); Text(L10n.text(device.name)) }
                    GridRow { Text("firmware_current").foregroundStyle(.secondary); Text(device.status?.firmwareVersion ?? L10n.text(device.identity.kind == .rom ? "rom_mode" : "common_unknown")) }
                    GridRow { Text("firmware_latest").foregroundStyle(.secondary); Text(L10n.text(app.firmware.latest)) }
                    GridRow { Text("firmware_strategy").foregroundStyle(.secondary); Text(L10n.text(app.firmware.strategy?.rawValue ?? "not_checked")) }
                }
                Text(L10n.text(app.firmware.message)).foregroundStyle(.secondary)
                if [.downloading, .writing].contains(app.firmware.phase) { ProgressView(value: app.firmware.progress).frame(maxWidth: 420) }
                if let error = app.firmware.error { Label(L10n.text(error), systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red).textSelection(.enabled) }
                HStack {
                    if app.firmware.phase == .ready { Button(L10n.text(app.firmware.strategy == .ota ? "install_update" : "factory_flash")) { confirming = true }.buttonStyle(.borderedProminent).disabled(app.busy) }
                    else if app.firmware.needsManualBoot { Button("retry_boot_reset") { app.retryManualFactoryFlash() }.buttonStyle(.borderedProminent).disabled(app.busy) }
                    else if ![.downloading, .writing, .reconnect].contains(app.firmware.phase) { Button(L10n.text(app.firmware.phase == .failed ? "common_retry" : "check_updates")) { app.checkFirmware() }.buttonStyle(.borderedProminent).disabled(app.busy) }
                }
            } else {
                RequirementPlaceholder(icon: "cable.connector", title: "connect_tinytouch_rom_mode", description: "runtime_native_cp210x_ch340")
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
                VStack(spacing: 6) { Text(L10n.text(title)).font(.largeTitle.bold()); Text(L10n.text(detail)).foregroundStyle(.secondary).multilineTextAlignment(.center) }
                VStack(alignment: .leading, spacing: 14) {
                    step("1", "board_ready", complete: true, active: false)
                    step("2", "fetch_verified_firmware", complete: hasFetchedFirmware, active: app.firmware.phase == .checking || app.firmware.phase == .downloading)
                    step("3", "connect_bootloader_flashing_board", complete: hasStartedWriting, active: app.firmware.phase == .writing && app.firmware.progress == 0)
                    step("4", "restart_board", complete: app.firmware.phase == .complete, active: app.firmware.phase == .writing && app.firmware.progress > 0)
                }.frame(maxWidth: 420, alignment: .leading)
                if app.firmware.phase == .checking || ([.downloading, .writing].contains(app.firmware.phase) && app.firmware.progress == 0) { ProgressView().frame(maxWidth: 420) }
                else if [.downloading, .writing].contains(app.firmware.phase) { ProgressView(value: app.firmware.progress).frame(maxWidth: 420) }
                if let error = app.firmware.error { Label(L10n.text(error), systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red).textSelection(.enabled) }
                if app.firmware.phase == .reconnect { Label("flash_complete_automatically_reconnects", systemImage: "cable.connector").foregroundStyle(.secondary).frame(maxWidth: 420, alignment: .leading) }
                else if app.firmware.phase == .complete { ProgressView().frame(maxWidth: 420) }
                else if app.firmware.needsManualBoot { Button("retry_boot_reset") { app.retryManualFactoryFlash() }.buttonStyle(.borderedProminent).disabled(app.busy) }
                else if app.canRetryNewBoardFactoryReset { Button("retry_factory_reset") { app.retryNewBoardFactoryReset() }.buttonStyle(.borderedProminent).disabled(app.busy) }
                else { Button(L10n.text(app.firmware.phase == .failed ? "try_again" : "download_flash")) { app.flashNewBoard() }.buttonStyle(.borderedProminent).disabled(app.busy) }
            }.padding(48).frame(maxWidth: 680).frame(maxWidth: .infinity)
        }
    }

    private var hasFetchedFirmware: Bool { [.downloading, .writing, .reconnect, .complete].contains(app.firmware.phase) }
    private var hasStartedWriting: Bool { (app.firmware.phase == .writing && app.firmware.progress > 0) || [.reconnect, .complete].contains(app.firmware.phase) }
    private var title: String { app.firmware.phase == .complete ? "board_ready" : "flash_new_board" }
    private var detail: String { app.firmware.phase == .complete ? "firmware_installed_set_tinytouch" : app.firmware.message }
    private func step(_ number: String, _ label: String, complete: Bool, active: Bool) -> some View {
        Label(L10n.text(label), systemImage: complete ? "checkmark.circle.fill" : active ? "arrow.triangle.2.circlepath.circle.fill" : "circle").foregroundStyle(complete ? .green : active ? .primary : .secondary).fontWeight(active ? .semibold : .regular).accessibilityLabel(L10n.text("step", number, L10n.text(label)))
    }
}
