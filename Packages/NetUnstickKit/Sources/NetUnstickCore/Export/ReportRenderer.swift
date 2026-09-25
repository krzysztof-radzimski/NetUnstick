import Foundation

public struct ReportPreview: Sendable, Equatable {
    public let sessionID: UUID
    public let title: String
    public let body: String
    public let entryCount: Int
}

public struct ReportRenderer: Sendable {
    public init() {}

    public func preview(session: ActivitySession) -> ReportPreview {
        ReportPreview(sessionID: session.id, title: "NetUnstick session report",
                      body: render(session: session), entryCount: session.entries.count)
    }

    public func render(session: ActivitySession) -> String {
        var lines = ["NetUnstick session report", "Format: 1", "Session ID: \(session.id.uuidString)",
                     "Started: \(date(session.startedAt))", "App version: \(session.appVersion)",
                     "macOS version: \(session.macOSVersion)", "Entries: \(session.entries.count)"]
        for (index, result) in session.entries.enumerated() {
            lines += ["", "\(index + 1). \(result.name) [\(result.operationID)]",
                      "Kind: \(result.kind.rawValue)", "Started: \(date(result.startedAt))",
                      "Ended: \(date(result.endedAt))",
                      "Duration: \(String(format: "%.3f", locale: Locale(identifier: "en_US_POSIX"), result.duration)) s",
                      "Outcome: \(result.outcome.rawValue)"]
            if let error = result.error { lines.append("Error: \(error.domain)/\(error.code)") }
            if let nextStep = result.nextStep { lines.append("Next step: \(nextStep)") }
            lines.append("Before: \(format(result.before))")
            lines.append("After: \(format(result.after))")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    public func utf8Data(session: ActivitySession) -> Data {
        Data(render(session: session).utf8)
    }

    private func date(_ value: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter.string(from: value)
    }

    private func format(_ evidence: SafeEvidence) -> String {
        guard !evidence.values.isEmpty else { return "none" }
        return evidence.values.sorted { $0.key.rawValue < $1.key.rawValue }
            .map { "\($0.key.rawValue)=\($0.value)" }.joined(separator: ", ")
    }
}
