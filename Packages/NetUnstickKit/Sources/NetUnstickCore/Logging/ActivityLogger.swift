import Foundation
import os

public struct ActivityLogRecord: Sendable {
    public let sessionID: UUID
    public let appVersion: String
    public let macOSVersion: String
    public let operationID: String
    public let operationName: String
    public let startedAt: Date
    public let duration: TimeInterval
    public let outcome: OperationOutcome
    public let errorDomain: String?
    public let errorCode: String?

    public init(session: ActivitySession, result: OperationResult) {
        sessionID = session.id
        appVersion = session.appVersion
        macOSVersion = session.macOSVersion
        operationID = result.operationID
        operationName = result.name
        startedAt = result.startedAt
        duration = result.duration
        outcome = result.outcome
        errorDomain = result.error?.domain
        errorCode = result.error?.code
    }

    /// Safe, deterministic text for tests and development diagnostics. Evidence is absent.
    public var text: String {
        let date = ISO8601DateFormatter().string(from: startedAt)
        return "session=\(sessionID.uuidString) app=\(appVersion) macOS=\(macOSVersion) operation=\(operationID) name=\(operationName) started=\(date) duration=\(String(format: "%.3f", duration)) outcome=\(outcome.rawValue) error=\(errorDomain ?? "none")/\(errorCode ?? "none")"
    }
}

public struct ActivityLogger: Sendable {
    private let logger: Logger

    public init(subsystem: String = "com.netunstick.app", category: String = "operations") {
        logger = Logger(subsystem: subsystem, category: category)
    }

    public func log(_ record: ActivityLogRecord) {
        // The whole dynamically assembled record remains private in Unified Logging.
        logger.log("\(record.text, privacy: .private)")
    }
}
