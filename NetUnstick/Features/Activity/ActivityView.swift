import SwiftUI
import NetUnstickCore

struct ActivityView: View {
    @ObservedObject var store: PresentationStore
    let showReport: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("activity").font(.largeTitle.bold())
            Picker("filter", selection: $store.filter) {
                Text("all").tag("all"); Text("success").tag("success"); Text("problems").tag("problems")
            }.pickerStyle(.segmented).accessibilityIdentifier("activity.filter")
            if store.filteredSessions.isEmpty {
                ContentUnavailableView("no_activity", systemImage: "clock", description: Text("no_activity_detail"))
            } else {
                List(store.filteredSessions, id: \.id) { session in
                    Section(session.startedAt.formatted(date: .abbreviated, time: .shortened)) {
                        ForEach(session.entries, id: \.operationID) { entry in
                            DisclosureGroup {
                                Text("\(entry.error?.domain ?? "") / \(entry.error?.code ?? "")")
                                    .font(.caption.monospaced()).textSelection(.enabled)
                            } label: {
                                HStack { Text(entry.name); Spacer(); Text(PresentationStore.outcomeTitle(entry.outcome)).foregroundStyle(.secondary) }
                            }
                        }
                    }
                }
            }
            Button("preview_report") { showReport() }
                .disabled(store.sessions.isEmpty).accessibilityIdentifier("report.preview.open")
        }.padding(28).navigationTitle("activity")
    }

}
