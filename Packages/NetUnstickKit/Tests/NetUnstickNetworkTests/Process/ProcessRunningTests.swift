import Foundation
import XCTest
@testable import NetUnstickNetwork

final class ProcessRunningTests: XCTestCase {
    func testCommandsUseOnlyFixedReadOnlyExecutablesAndArguments() {
        let commands: [(ReadOnlyNetworkCommand, String, [String])] = [
            (.routeGetDefault, "/sbin/route", ["-n", "get", "default"]),
            (.netstatIPv4, "/usr/sbin/netstat", ["-rn", "-f", "inet"]),
            (.netstatIPv6, "/usr/sbin/netstat", ["-rn", "-f", "inet6"]),
            (.scutilDNS, "/usr/sbin/scutil", ["--dns"]),
            (.scutilProxy, "/usr/sbin/scutil", ["--proxy"]),
        ]
        for (command, executable, arguments) in commands {
            XCTAssertEqual(command.executable, executable)
            XCTAssertEqual(command.arguments, arguments)
            XCTAssertTrue(command.arguments.allSatisfy { !$0.contains(";") && !$0.contains("$") })
        }
    }

    func testRawOutputCannotBeEncodedAndDescriptionsAreRedacted() {
        let output = ProcessOutput(stdout: "secret.example.internal", stderr: "private-token", exitStatus: 0)
        XCTAssertFalse(ProcessOutput.self is any Encodable.Type)
        XCTAssertFalse(String(describing: output).contains("secret"))
        XCTAssertFalse(String(reflecting: output).contains("private-token"))
    }

    func testErrorCodesDoNotIncludeOutput() {
        XCTAssertEqual(ProcessRunError.permissionDenied.code, "process.permission_denied")
        XCTAssertEqual(ProcessRunError.timedOut.code, "process.timeout")
        XCTAssertEqual(ProcessRunError.cancelled.code, "process.cancelled")
        XCTAssertEqual(ProcessRunError.outputTooLarge.code, "process.output_too_large")
        XCTAssertEqual(ProcessRunError.nonZeroExit(42).code, "process.nonzero_exit")
        XCTAssertEqual(ProcessRunError.invalidEncoding.code, "process.invalid_encoding")
    }

    func testOutputLimitStopsReadOnlyCommand() async throws {
        let runner = SystemProcessRunner(timeout: 3, outputLimit: 1)
        do {
            _ = try await runner.run(.netstatIPv4)
            XCTFail("Expected output limit failure")
        } catch let error as ProcessRunError {
            XCTAssertEqual(error, .outputTooLarge)
        }
    }

    func testReadOnlyCommandReturnsBoundedOutput() async throws {
        let runner = SystemProcessRunner(timeout: 3, outputLimit: 65_536)
        let output = try await runner.run(.netstatIPv4)
        XCTAssertEqual(output.exitStatus, 0)
        XCTAssertFalse(output.stdout.isEmpty)
        XCTAssertLessThanOrEqual(output.stdout.utf8.count, runner.outputLimit)
        XCTAssertLessThanOrEqual(output.stderr.utf8.count, runner.outputLimit)
    }

    func testCancellationBeforeLaunchIsReported() async throws {
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await SystemProcessRunner().run(.netstatIPv4)
        }
        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch let error as ProcessRunError {
            XCTAssertEqual(error, .cancelled)
        }
    }
}
