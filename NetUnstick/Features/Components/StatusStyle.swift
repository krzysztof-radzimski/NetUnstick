import SwiftUI
import NetUnstickCore

private struct StatusHighContrastKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// Carries the app's live macOS contrast observation and the Debug appearance override.
    var statusHighContrast: Bool {
        get { self[StatusHighContrastKey.self] }
        set { self[StatusHighContrastKey.self] = newValue }
    }
}

/// Color supplements the existing outcome text and symbol; it never determines a verdict.
enum StatusTone {
    case accent, information, success, attention, failure, neutral

    init(state: NetworkPresentationState) {
        switch state {
        case .healthy: self = .success
        case .problem: self = .failure
        case .investigating: self = .accent
        case .unknown, .residual, .residualRoutes, .serverNotReady: self = .attention
        }
    }

    init(outcome: OperationOutcome) {
        switch outcome {
        case .success: self = .success
        case .failure: self = .failure
        case .permissionDenied, .timedOut: self = .attention
        case .skipped, .cancelled: self = .neutral
        }
    }

    var color: Color {
        switch self {
        case .accent: .accentColor
        case .information: .teal
        case .success: .green
        case .attention: .orange
        case .failure: .red
        case .neutral: .secondary
        }
    }
}

extension OperationOutcome {
    var statusSymbol: String {
        switch self {
        case .success: "checkmark.circle"
        case .failure: "exclamationmark.triangle"
        case .permissionDenied: "hand.raised"
        case .timedOut: "clock.badge.exclamationmark"
        case .skipped: "minus.circle"
        case .cancelled: "stop.circle"
        }
    }
}

struct StatusIcon: View {
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.statusHighContrast) private var highContrast
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    let symbol: String
    var tone: StatusTone = .information
    var size: CGFloat = 38
    var isWorking = false
    var completion = 0

    private var reduceMotion: Bool {
        systemReduceMotion || CompositionRoot.testOption("--ui-reduce-motion")
    }

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.46, weight: .semibold))
            .foregroundStyle(highContrast || contrast == .increased ? Color.primary : tone.color)
            .symbolEffect(.pulse, options: .speed(0.7), isActive: isWorking && !reduceMotion)
            .symbolEffect(.bounce, options: .nonRepeating, value: completion)
            .symbolEffectsRemoved(reduceMotion)
            .frame(width: size, height: size)
            .background(tone.color.opacity(0.12), in: RoundedRectangle(cornerRadius: size * 0.30))
            .accessibilityHidden(true)
    }
}

/// Keeps text at the system's normal contrast and tints only the accompanying icon.
struct StatusLabelStyle: LabelStyle {
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.statusHighContrast) private var highContrast
    var tone: StatusTone = .information

    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 8) {
            configuration.icon
                .foregroundStyle(highContrast || contrast == .increased ? Color.primary : tone.color)
                .accessibilityHidden(true)
            configuration.title
        }
    }
}

private struct StatusPanel: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.statusHighContrast) private var contrastOverride
    let tone: StatusTone
    let emphasized: Bool
    let contentPadding: CGFloat?

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: 18, style: .continuous)
        content
            .padding(contentPadding ?? (emphasized ? 24 : 20))
            .frame(maxWidth: .infinity, alignment: .leading)
            // An opaque system surface also respects Reduce Transparency, without a blur.
            .background {
                shape.fill(Color(nsColor: .controlBackgroundColor))
                    .overlay {
                        shape.fill(LinearGradient(
                            colors: [tone.color.opacity(tintOpacity), tone.color.opacity(0.025)],
                            startPoint: .topLeading, endPoint: .bottomTrailing))
                    }
            }
            .overlay {
                shape.strokeBorder(highContrast ? Color.primary : tone.color.opacity(emphasized ? 0.30 : 0.18),
                                   lineWidth: highContrast ? 2 : 1)
                    .allowsHitTesting(false)
            }
    }

    private var tintOpacity: Double {
        if highContrast { return 0.035 }
        return colorScheme == .dark ? 0.16 : 0.08
    }

    private var highContrast: Bool { contrastOverride || contrast == .increased }
}

extension View {
    func statusPanel(tone: StatusTone = .information, emphasized: Bool = false, contentPadding: CGFloat? = nil) -> some View {
        modifier(StatusPanel(tone: tone, emphasized: emphasized, contentPadding: contentPadding))
    }
}
