import SwiftUI

struct InformationDialog: View {
    let title: String
    let message: String
    var icon = "info.circle"

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon).foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.callout.weight(.semibold))
                Text(message).font(.callout).foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .background(Color.accentColor.opacity(0.1), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

struct FingerprintPromptView: View {
    let message: String
    var body: some View {
        ZStack {
            Color.black.opacity(0.3).ignoresSafeArea()
            VStack(spacing: 16) {
                Image(systemName: "touchid").font(.system(size: 42)).foregroundStyle(.tint)
                Text("Fingerprint Required").font(.title2.bold())
                Text(message).foregroundStyle(.secondary)
                ProgressView()
            }.padding(28).frame(minWidth: 320).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous)).shadow(radius: 24)
        }.transition(.opacity).accessibilityElement(children: .combine).accessibilityAddTraits(.isModal)
    }
}

struct DevicePicker: View {
    @EnvironmentObject private var app: AppState
    var body: some View {
        HStack(spacing: 12) {
            if app.devices.count > 1 {
                Picker("Device", selection: $app.selectedID) { ForEach(app.devices) { Text($0.name).tag(Optional($0.id)) } }.frame(maxWidth: 360).disabled(app.busy)
            } else {
                VStack(alignment: .leading, spacing: 2) {
                    Text(app.selectedDevice?.name ?? "No tinyTouch connected").font(.headline)
                    Label(status, systemImage: "circle.fill").font(.caption).foregroundStyle(statusColor).labelStyle(.titleAndIcon)
                }
            }
            Spacer()
            if app.busy { ProgressView().controlSize(.small) }
            Button { app.refresh() } label: { Image(systemName: "arrow.clockwise") }.help("Refresh or retry this device").disabled(app.selectedDevice == nil || app.busy)
        }.padding(.horizontal, 22).padding(.vertical, 13).background(.thinMaterial).overlay(alignment: .bottom) { Rectangle().fill(.white.opacity(0.14)).frame(height: 1) }
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

struct Page<Content: View>: View {
    let title: String
    let icon: String
    @ViewBuilder let content: Content
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                HStack(spacing: 14) {
                    Image(systemName: icon).font(.title2.bold()).foregroundStyle(.tint).frame(width: 44, height: 44).background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    Text(title).font(.largeTitle.bold())
                }
                VStack(alignment: .leading, spacing: 18) { content }.frame(maxWidth: .infinity, alignment: .leading)
            }.frame(maxWidth: 820, alignment: .leading).padding(28)
        }.scrollContentBackground(.hidden)
    }
}

struct DeviceMessageView: View {
    @EnvironmentObject private var app: AppState
    var body: some View {
        if let message = app.selectedDevice?.message {
            Label(message, systemImage: app.selectedDevice?.isError == true ? "exclamationmark.triangle.fill" : "checkmark.circle.fill").foregroundStyle(app.selectedDevice?.isError == true ? .red : .green).textSelection(.enabled)
        }
    }
}

struct AppMessageView: View {
    @EnvironmentObject private var app: AppState
    var body: some View {
        if let message = app.appMessage {
            Label(message, systemImage: app.appMessageIsError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill").foregroundStyle(app.appMessageIsError ? .red : .green).textSelection(.enabled)
        }
    }
}

struct RequirementPlaceholder: View {
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
            if let actionTitle, let action { Button(actionTitle, action: action).buttonStyle(.borderedProminent) }
        }.frame(maxWidth: .infinity).padding(.vertical, 60)
    }
}

@MainActor @ViewBuilder func availableDevice<Content: View>(_ app: AppState, @ViewBuilder content: (DeviceViewState, DeviceStatus) -> Content) -> some View {
    if !app.backgroundEnabled {
        RequirementPlaceholder(icon: "pause.circle", title: "HID service is paused", description: "Enable the HID service to communicate with tinyTouch.", actionTitle: "Enable HID Service", action: { app.setBackgroundEnabled(true) })
    } else if let device = app.selectedDevice {
        if device.connection == .error {
            RequirementPlaceholder(icon: "exclamationmark.triangle", title: "Connection failed", description: device.message ?? "TinyTouch could not connect to this device.", actionTitle: "Retry", action: { app.refresh() })
        } else if let status = device.status {
            content(device, status)
        } else {
            VStack(spacing: 12) { ProgressView(); Text("Reading device status…").foregroundStyle(.secondary) }.frame(maxWidth: .infinity).padding(.vertical, 60)
        }
    } else {
        RequirementPlaceholder(icon: "cable.connector", title: "Connect tinyTouch with a USB data cable", description: "A USB data connection is required to use this feature.")
    }
}

struct LiquidBackdrop: View {
    var body: some View {
        ZStack {
            LinearGradient(colors: [Color.accentColor.opacity(0.16), .clear, Color.purple.opacity(0.1)], startPoint: .topLeading, endPoint: .bottomTrailing)
            Circle().fill(Color.cyan.opacity(0.12)).frame(width: 380).blur(radius: 70).offset(x: 240, y: -190)
            Circle().fill(Color.purple.opacity(0.11)).frame(width: 320).blur(radius: 80).offset(x: -260, y: 210)
        }.ignoresSafeArea().accessibilityHidden(true)
    }
}
