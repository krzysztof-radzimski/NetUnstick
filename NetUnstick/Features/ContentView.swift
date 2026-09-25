import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @StateObject private var store = PresentationStore(service: MockPresentationService.fromLaunchArguments())
    @State private var section = "status"
    @State private var repairSheet = false
    @State private var previewSheet = false
    @State private var exporter = false
    @State private var exportError = false
    @State private var report = TextReport(text: "")
    @State private var highContrast = ProcessInfo.processInfo.arguments.contains("--ui-contrast") || NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast

    var body: some View {
        NavigationSplitView {
            List(selection: $section) {
                Label("status", systemImage: "waveform.path").tag("status").accessibilityIdentifier("nav.status")
                Label("activity", systemImage: "clock.arrow.circlepath").tag("activity").accessibilityIdentifier("nav.activity")
                Label("settings", systemImage: "gearshape").tag("settings").accessibilityIdentifier("nav.settings")
            }.navigationTitle("NetUnstick").frame(minWidth: 180)
        } detail: {
            Group {
                switch section {
                case "activity": ActivityView(store: store) { previewSheet = true }
                case "settings": SettingsView(store: store)
                default: DashboardView(store: store, highContrast: highContrast) { repairSheet = true }
                }
            }.frame(minWidth: 560, minHeight: 500)
        }
        .sheet(isPresented: $repairSheet) { RepairConfirmationView(store: store) { repairSheet = false } }
        .sheet(isPresented: $previewSheet) { ReportPreviewView(store: store, dismiss: { previewSheet = false }) {
            report = TextReport(text: store.reportText)
            previewSheet = false
            DispatchQueue.main.async { exporter = true }
        } }
        .fileExporter(isPresented: $exporter, document: report, contentType: .plainText, defaultFilename: "NetUnstick-report") { result in
            if case .failure(let error) = result {
                let ns = error as NSError
                if !(ns.domain == NSCocoaErrorDomain && ns.code == NSUserCancelledError) { exportError = true }
            }
        }
        .alert("export_failed", isPresented: $exportError) {
            Button("ok", role: .cancel) { }
        } message: { Text("export_failed_detail") }
        .background {
            Button("") { store.startDiagnosis() }.keyboardShortcut("d", modifiers: .command).hidden()
            Button("") { store.cancel() }.keyboardShortcut(.escape, modifiers: []).hidden()
            Button("") { if !store.sessions.isEmpty { previewSheet = true } }.keyboardShortcut("e", modifiers: [.command, .shift]).hidden()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification)) { _ in
            highContrast = ProcessInfo.processInfo.arguments.contains("--ui-contrast") || NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
        }
    }

}
