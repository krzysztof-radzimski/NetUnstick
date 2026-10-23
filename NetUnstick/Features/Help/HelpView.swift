import SwiftUI
import NetUnstickCore

enum HelpTopic: String, CaseIterable, Identifiable {
    case gettingStarted, results, device, repairs, privacy, safety, support
    var id: String { rawValue }
    var title: String { L10n.text("help_" + rawValue) }
    var symbol: String {
        switch self {
        case .gettingStarted: "play.circle"
        case .results: "checklist"
        case .device: "desktopcomputer"
        case .repairs: "wrench.adjustable"
        case .privacy: "hand.raised"
        case .safety: "lock.shield"
        case .support: "questionmark.circle"
        }
    }
    var sections: [String] {
        switch self {
        case .gettingStarted: ["help_start", "help_scope", "help_shortcuts"]
        case .results: ["help_results", "help_inconclusive", "help_vpn"]
        case .device: ["help_device", "help_device_privacy"]
        case .repairs: ["help_repair", "help_helper", "help_repair_limits"]
        case .privacy: ["privacy_local", "privacy_network", "privacy_retention", "privacy_permissions", "privacy_version"]
        case .safety: ["help_safety", "help_reports"]
        case .support: ["help_support", "help_accessibility"]
        }
    }
}

@MainActor final class HelpNavigation: ObservableObject {
    static let shared = HelpNavigation()
    @Published var topic: HelpTopic = .gettingStarted

    func show(_ topic: HelpTopic, openWindow: OpenWindowAction) {
        self.topic = topic
        openWindow(id: "help")
    }
}

struct HelpView: View {
    @ObservedObject private var navigation = HelpNavigation.shared

    var body: some View {
        NavigationSplitView {
            List(HelpTopic.allCases, selection: $navigation.topic) { topic in
                Label(topic.title, systemImage: topic.symbol).tag(topic)
                    .help(topic.title)
                    .accessibilityIdentifier("help.topic." + topic.rawValue)
            }
            .navigationTitle(L10n.text("help_title"))
            .navigationSplitViewColumnWidth(min: 240, ideal: 280, max: 360)
            .frame(minWidth: 240)
        } detail: {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    Label(navigation.topic.title, systemImage: navigation.topic.symbol)
                        .font(.largeTitle.bold())
                    ForEach(navigation.topic.sections, id: \.self) { section in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(L10n.text(section + "_title")).font(.headline)
                            Text(L10n.text(section + "_body"))
                                .textSelection(.enabled)
                        }
                    }
                }
                .padding(28)
                .frame(maxWidth: 720, alignment: .leading)
            }
            .frame(minWidth: 430, minHeight: 430)
            .navigationTitle(navigation.topic.title)
            .accessibilityIdentifier("help.content")
        }
    }
}

struct NetUnstickHelpCommands: Commands {
    @Environment(\.openWindow) private var openWindow
    var body: some Commands {
        CommandGroup(replacing: .help) {
            Button(L10n.text("help_title")) {
                HelpNavigation.shared.show(.gettingStarted, openWindow: openWindow)
            }.keyboardShortcut("?", modifiers: .command)
            Button(L10n.text("help_privacy")) {
                HelpNavigation.shared.show(.privacy, openWindow: openWindow)
            }
            Button(L10n.text("help_safety")) {
                HelpNavigation.shared.show(.safety, openWindow: openWindow)
            }
        }
    }
}
