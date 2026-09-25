import Foundation
import XCTest
import NetUnstickCore

final class OperationContractTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_700_000_000)

    func testAllOutcomesAndRequiredErrorCodesRoundTrip() throws {
        for outcome in OperationOutcome.allCases {
            let needsError: Bool = [.failure, .permissionDenied, .timedOut].contains(outcome)
            let error = needsError ? try OperationError(domain: "netunstick.operation", code: outcome.rawValue) : nil
            let result = try OperationResult(operationID: "check.network", name: "check.network",
                                             kind: .diagnostic, startedAt: start,
                                             endedAt: start.addingTimeInterval(2.5), outcome: outcome,
                                             error: error, nextStep: NextStep.retryCheck.rawValue)
            XCTAssertEqual(result.duration, 2.5)
            XCTAssertEqual(try JSONDecoder().decode(OperationResult.self, from: JSONEncoder().encode(result)), result)
            XCTAssertEqual(result.error?.code, error?.code)
            if needsError {
                XCTAssertThrowsError(try OperationResult(operationID: "check.network", name: "check.network",
                                                         kind: .diagnostic, startedAt: start, endedAt: start,
                                                         outcome: outcome)) { error in
                    XCTAssertEqual(error as? OperationContractError, .missingErrorCode)
                }
            }
        }
    }

    func testInvalidIdentityAndTimeRangeAreRejected() throws {
        XCTAssertThrowsError(try OperationResult(operationID: "a user name", name: "test", kind: .diagnostic,
                                                 startedAt: start, endedAt: start, outcome: .success))
        XCTAssertThrowsError(try OperationResult(operationID: "check.network", name: "test", kind: .diagnostic,
                                                 startedAt: start, endedAt: start.addingTimeInterval(-1), outcome: .success))
        XCTAssertThrowsError(try OperationError(domain: "private domain", code: "failure"))
    }

    func testClockAndCancellationCanBeControlled() throws {
        let context = OperationContext(clock: FixedClock(date: start), cancellation: FixedCancellation(cancelled: false))
        XCTAssertEqual(context.clock.now(), start)
        XCTAssertNoThrow(try context.cancellation.checkCancellation())
        let cancelled = OperationContext(clock: FixedClock(date: start), cancellation: FixedCancellation(cancelled: true))
        XCTAssertThrowsError(try cancelled.cancellation.checkCancellation()) { XCTAssertTrue($0 is CancellationError) }
    }
}

private struct FixedClock: OperationClock {
    let date: Date
    func now() -> Date { date }
}

private struct FixedCancellation: CancellationChecking {
    let cancelled: Bool
    func checkCancellation() throws { if cancelled { throw CancellationError() } }
}
