import SwiftUI
import NetUnstickCore

struct ActivityView: View {
    @ObservedObject var store: PresentationStore
    let showReport: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(L10n.text("activity")).font(.largeTitle.bold())
            Picker(L10n.text("filter"), selection: $store.filter) {
                Text(L10n.text("all")).tag("all"); Text(L10n.text("success")).tag("success"); Text(L10n.text("problems")).tag("problems")
            }.pickerStyle(.segmented).accessibilityIdentifier("activity.filter")
            if store.filteredSessions.isEmpty {
                ContentUnavailableView(L10n.text("no_activity"), systemImage: "clock", description: Text(L10n.text("no_activity_detail")))
            } else {
                List(store.filteredSessions, id: \.id) { session in
                    Section(session.startedAt.formatted(date: .abbreviated, time: .shortened)) {
                        Button(L10n.text("select_session")) { store.selectSession(session.id) }
                            .accessibilityIdentifier("session.\(session.id.uuidString)")
                        ForEach(session.entries, id: \.operationID) { entry in
                            DisclosureGroup {
                                Text("\(entry.error?.domain ?? "") / \(entry.error?.code ?? "")")
                                    .font(.caption.monospaced()).textSelection(.enabled)
                                ForEach(entry.after.values.keys.sorted(by: { $0.rawValue < $1.rawValue }), id: \.rawValue) { key in
                                    Text("\(key.rawValue): \(entry.after.values[key] ?? "")").font(.caption.monospaced())
                                }
                            } label: {
                                HStack { Text(PresentationStore.operationTitle(entry.name)); Spacer(); Text(PresentationStore.outcomeTitle(entry.outcome)).foregroundStyle(.secondary) }
                            }
                        }
                    }
                }
            }
            Button(L10n.text("preview_report")) { showReport() }
                .disabled(store.sessions.isEmpty).accessibilityIdentifier("report.preview.open")
        }.padding(28).navigationTitle(L10n.text("activity"))
    }

}
