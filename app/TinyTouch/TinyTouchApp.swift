import AppKit
import SwiftUI

@MainActor
final class ApplicationDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        AppState.active?.isFirmwareWriting == true ? .terminateCancel : .terminateNow
    }
}

@main
struct TinyTouchApp: App {
    @NSApplicationDelegateAdaptor(ApplicationDelegate.self) private var delegate
    @StateObject private var app = AppState()

    var body: some Scene {
        MenuBarExtra {
            MenuContent().environmentObject(app).environment(\.locale, app.language.locale)
        } label: {
            Image(systemName: app.menuIcon)
                .accessibilityLabel(L10n.text("tinytouch_detail", app.summary))
        }
        .menuBarExtraStyle(.menu)
    }
}

private struct MenuContent: View {
    @EnvironmentObject private var app: AppState

    var body: some View {
        Button(L10n.text(app.summary)) { app.showWindow() }.keyboardShortcut("o")
        if app.showsHIDServiceControls {
            Toggle("enable_hid_service", isOn: Binding(
                get: { app.backgroundEnabled }, set: { app.setBackgroundEnabled($0) }
            )).disabled(app.isFirmwareWriting)
            Toggle("launch_login", isOn: Binding(
                get: { app.launchAtLogin }, set: { app.setLaunchAtLogin($0) }
            ))
        }
        Divider()
        Button("common_quit") { NSApplication.shared.terminate(nil) }.keyboardShortcut("q").disabled(app.isFirmwareWriting)
    }
}
