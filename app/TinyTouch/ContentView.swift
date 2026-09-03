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
                            Image("TinyTouchIcon").resizable().scaledToFit().frame(width: 38, height: 38)
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
