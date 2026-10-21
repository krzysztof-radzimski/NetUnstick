import Foundation
import XCTest
import NetUnstickCore

final class ReportGuidanceTests: XCTestCase {
    func testLegacyGuidanceRemainsDecodableButExportUsesCurrentSafeText() throws {
        for step in [NextStep.disableLocalFirewall, .limitSMBToVersion2, .registerHelper] {
            let now = Date(timeIntervalSince1970: 1_700_000_000)
            let result = try OperationResult(operationID: "device_connection", name: "device_connection",
                kind: .diagnostic, startedAt: now, endedAt: now, outcome: .success, nextStep: step.rawValue)
            let encoded = try JSONEncoder().encode(result)
            let restored = try JSONDecoder().decode(OperationResult.self, from: encoded)
            XCTAssertEqual(restored.nextStep, step.rawValue, "Stored allowlist values retain backwards compatibility")
            let session = ActivitySession(startedAt: now, appVersion: "1", macOSVersion: "14", entries: [restored])
            let report = ReportRenderer().render(session: session)
            XCTAssertTrue(report.contains("Next step: " + L10n.nextStep(step.rawValue, locale: Locale(identifier: "en"))))
            XCTAssertFalse(report.contains("Turn off the firewall"))
            XCTAssertFalse(report.contains("protocol_vers_map=2"))
            XCTAssertEqual(try JSONEncoder().encode(restored).count, encoded.count)
        }
    }
}
