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
            MenuContent().environmentObject(app)
        } label: {
            Image(systemName: app.menuIcon)
                .accessibilityLabel("tinyTouch: \(app.summary)")
        }
        .menuBarExtraStyle(.menu)
    }
}

private struct MenuContent: View {
    @EnvironmentObject private var app: AppState

    var body: some View {
        Button(app.summary) { app.showWindow() }.keyboardShortcut("o")
        Toggle("Enable HID Service", isOn: Binding(
            get: { app.backgroundEnabled }, set: { app.setBackgroundEnabled($0) }
        )).disabled(app.isFirmwareWriting)
        Toggle("Launch at Login", isOn: Binding(
            get: { app.launchAtLogin }, set: { app.setLaunchAtLogin($0) }
        ))
        Divider()
        Button("Quit") { NSApplication.shared.terminate(nil) }.keyboardShortcut("q").disabled(app.isFirmwareWriting)
    }
}
