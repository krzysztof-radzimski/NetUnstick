import SwiftUI
import NetUnstickCore

struct ReportPreviewView: View {
    @ObservedObject var store: PresentationStore
    let dismiss: () -> Void
    let save: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(L10n.text("report_preview")).font(.title.bold()).accessibilityIdentifier("report.preview")
            Text(L10n.text("report_redacted")).foregroundStyle(.secondary)
            ScrollView { Text(store.reportText).font(.body.monospaced()).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled).padding() }
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
                .accessibilityIdentifier("report.preview.text")
            HStack { Spacer(); Button(L10n.text("cancel")) { dismiss() }.accessibilityIdentifier("report.cancel"); Button(L10n.text("save_report")) {
                save()
            }.buttonStyle(.borderedProminent).accessibilityIdentifier("report.save") }
        }.padding(28).frame(width: 650, height: 520)
    }
}
