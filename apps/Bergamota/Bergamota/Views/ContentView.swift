import SwiftUI

enum SidebarItem: String, CaseIterable, Identifiable {
    case dashboard = "Dashboard", performance = "Performance", log = "Live Log", boot = "Boot Queue", ci = "CI", apps = "Apps", media = "Media", settings = "Settings"
    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .dashboard: "rectangle.grid.2x2"
        case .performance: "gauge.with.dots.needle.67percent"
        case .log: "text.alignleft"
        case .boot: "bolt.horizontal.circle"
        case .ci: "hammer"
        case .apps: "square.grid.3x3"
        case .media: "photo.on.rectangle"
        case .settings: "gearshape"
        }
    }
}

struct ContentView: View {
    @Environment(AppModel.self) private var model
    @State private var selection: SidebarItem? = DesignPreview.section.flatMap { s in SidebarItem.allCases.first { $0.rawValue.lowercased().replacingOccurrences(of: " ", with: "") == s } } ?? .dashboard
    @AppStorage("showStateRail") private var showRail = true
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        NavigationSplitView {
            List(SidebarItem.allCases, selection: $selection) { item in
                Label(item.rawValue, systemImage: item.symbol)
                    .badge(item == .boot ? model.queue.pending.count : 0)
                    .tag(item)
            }
            .navigationSplitViewColumnWidth(min: 170, ideal: 196)
            .safeAreaInset(edge: .bottom) {
                // the phone's state stays visible here when the rail is hidden
                if !showRail {
                    HStack(spacing: 8) {
                        Pill(text: model.monitor.state.title, tone: stateTone(model.monitor.state), size: 9.5)
                        Spacer(minLength: 0)
                    }
                    .padding(12)
                }
            }
        } detail: {
            Group {
                switch selection ?? .dashboard {
                case .dashboard: DashboardView()
                case .performance: PerformanceView()
                case .log: LogView()
                case .boot: BootView()
                case .ci: CIView()
                case .apps: AppsView()
                case .media: MediaView()
                case .settings: SettingsView()
                }
            }
            .toolbar(removing: .title)
        }
        .inspector(isPresented: $showRail) {
            StateRail()
                .ignoresSafeArea(.container, edges: .top)
                .inspectorColumnWidth(min: 290, ideal: 330, max: 420)
        }
        .tint(.leafText)
        .task {
            if UserDefaults.standard.bool(forKey: "openControlPlane") || DesignPreview.section == "controlplane" { openWindow(id: "control-plane") }
            if DesignPreview.active { DesignPreview.snapshotAndQuit("\(DesignPreview.scenario ?? "")-\(DesignPreview.section ?? "dashboard")") }
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button { openWindow(id: "control-plane") } label: { Label("Control Plane", systemImage: "rectangle.on.rectangle") }
                    .help("Open the Control Plane window (large type, for a second display)")
                Button { showRail.toggle() } label: { Label("Phone", systemImage: "sidebar.right") }
                    .help(showRail ? "Hide the phone rail" : "Show the phone rail")
            }
        }
    }
}
