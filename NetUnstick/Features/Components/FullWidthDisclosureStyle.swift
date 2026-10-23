import SwiftUI

/// The header is one native button, including its padding and empty trailing space.
/// Expanded content stays outside that button so its controls and text work independently.
struct FullWidthDisclosureStyle: DisclosureGroupStyle {
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    var headerInsets = EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0)

    func makeBody(configuration: Configuration) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.22)) {
                    configuration.isExpanded.toggle()
                }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(configuration.isExpanded ? 90 : 0))
                        .accessibilityHidden(true)
                    configuration.label
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(headerInsets)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityRepresentation {
                // Preserve the system's localized expanded/collapsed state and action.
                DisclosureGroup(isExpanded: Binding(
                    get: { configuration.isExpanded },
                    set: { configuration.isExpanded = $0 }
                )) {
                    EmptyView()
                } label: {
                    configuration.label
                }
                .disclosureGroupStyle(.automatic)
            }

            if configuration.isExpanded {
                configuration.content
                    .disclosureGroupStyle(FullWidthDisclosureStyle())
                    .padding(EdgeInsets(top: 0, leading: headerInsets.leading,
                                        bottom: headerInsets.bottom, trailing: headerInsets.trailing))
                    .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var reduceMotion: Bool {
        systemReduceMotion || CompositionRoot.testOption("--ui-reduce-motion")
    }
}
