import Foundation
import XCTest
@testable import NetUnstick

private final class RegistrationFixture: @unchecked Sendable {
    let removalStarted = XCTestExpectation(description: "unregistration requested")
    private let lock = NSLock()
    private var completion: ((Error?) -> Void)?
    private var registrations = 0

    var registrationCount: Int {
        lock.lock(); defer { lock.unlock() }
        return registrations
    }
    func unregister(_ completion: @escaping (Error?) -> Void) {
        lock.lock()
        self.completion = completion
        lock.unlock()
        removalStarted.fulfill()
    }
    func finishRemoval(_ error: Error? = nil) {
        lock.lock()
        let callback = completion
        lock.unlock()
        callback?(error)
    }
    func register() -> HelperRegistrationStatus {
        lock.lock()
        registrations += 1
        lock.unlock()
        return .enabled
    }
}

final class HelperRegistrationTests: XCTestCase {
    func testReplacementWaitsForRemovalCompletionAndRegistersOnlyOnce() async throws {
        let fixture = RegistrationFixture()
        let task = Task {
            try await HelperRegistrationRefresh.perform(
                unregister: fixture.unregister, register: fixture.register, timeout: .seconds(2))
        }
        await fulfillment(of: [fixture.removalStarted], timeout: 1)
        // A synchronous status change cannot substitute for the system's completion.
        XCTAssertEqual(fixture.registrationCount, 0)
        fixture.finishRemoval()
        let result = try await task.value
        XCTAssertEqual(result, .enabled)
        fixture.finishRemoval()
        XCTAssertEqual(fixture.registrationCount, 1)
    }

    func testRemovalTimeoutDoesNotRegisterEvenIfCompletionArrivesLate() async {
        let fixture = RegistrationFixture()
        do {
            _ = try await HelperRegistrationRefresh.perform(
                unregister: fixture.unregister, register: fixture.register, timeout: .milliseconds(30))
            XCTFail("A missing system callback must time out.")
        } catch HelperRegistrationRefreshError.timedOut {
            fixture.finishRemoval()
            XCTAssertEqual(fixture.registrationCount, 0)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testFailedRemovalDoesNotRegister() async {
        let fixture = RegistrationFixture()
        let error = NSError(domain: "registration-fixture", code: 42)
        do {
            _ = try await HelperRegistrationRefresh.perform(
                unregister: { $0(error) }, register: fixture.register)
            XCTFail("A failed removal must stop the migration.")
        } catch let actual as NSError {
            XCTAssertEqual(actual.domain, error.domain)
            XCTAssertEqual(actual.code, error.code)
            XCTAssertEqual(fixture.registrationCount, 0)
        }
    }

    func testCancellationStopsWaitingAndIgnoresLaterRemovalCompletion() async {
        let fixture = RegistrationFixture()
        let task = Task {
            try await HelperRegistrationRefresh.perform(
                unregister: fixture.unregister, register: fixture.register, timeout: .seconds(2))
        }
        await fulfillment(of: [fixture.removalStarted], timeout: 1)
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("Cancellation must stop the migration.")
        } catch is CancellationError {
            fixture.finishRemoval()
            XCTAssertEqual(fixture.registrationCount, 0)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }
}
