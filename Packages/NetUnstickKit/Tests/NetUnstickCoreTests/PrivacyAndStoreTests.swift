import Foundation
import XCTest
import NetUnstickCore

final class PrivacyAndStoreTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_700_000_000)

    private func result(_ index: Int = 0, before: SafeEvidence = .empty) throws -> OperationResult {
        try OperationResult(operationID: "check.network", name: "check.network", kind: .diagnostic,
                            startedAt: start, endedAt: start.addingTimeInterval(Double(index + 1)),
                            outcome: .failure, before: before,
                            error: OperationError(domain: "netunstick.network", code: "unavailable"),
                            nextStep: NextStep.retryCheck.rawValue)
    }

    private func temporaryURL() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("sessions.json")
    }

    func testSensitiveValuesAbsentFromLoggableAndExportedText() throws {
        let secrets = ["Corp-WiFi-Secret", "Living Room Apple TV", "8.8.8.8", "192.168.1.25",
                       "printer.corp.internal", "/Users/alice/private", "sk_test_abc123secret",
                       "password=supersecret", "stdout: route to private host"]
        let evidence = EvidenceSanitizer.sanitize([
            .networkStatus: .status(.unavailable), .count: .count(2),
            .interfaceType: .interfaceType(.wifi), .errorCode: .errorCode("route_failed")
        ])
        let rejected = EvidenceSanitizer.sanitize([.networkStatus: .sensitive(secrets.joined(separator: " "))])
        XCTAssertTrue(rejected.values.isEmpty)
        let session = ActivitySession(startedAt: start, appVersion: "1.0", macOSVersion: "14.0",
                                      entries: [try result(before: evidence)])
        let report = ReportRenderer().render(session: session)
        let preview = ReportRenderer().preview(session: session)
        let logText = ActivityLogRecord(session: session, result: session.entries[0]).text
        let allText = report + preview.body + logText
        for secret in secrets { XCTAssertFalse(allText.contains(secret), "Leaked sensitive fixture") }
        XCTAssertTrue(report.contains("Session ID: \(session.id.uuidString)"))
        XCTAssertTrue(report.contains("networkStatus=unavailable"))
        XCTAssertEqual(ReportRenderer().utf8Data(session: session), Data(report.utf8))
        XCTAssertEqual(report, ReportRenderer().render(session: session))
        XCTAssertFalse(logText.contains("networkStatus"))
    }

    func testSessionAndEntryLimitsSurviveReload() async throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = try BoundedSessionStore(fileURL: url)
        let first = ActivitySession(startedAt: start, appVersion: "1.0", macOSVersion: "14.0")
        try await store.startSession(first)
        for index in 0..<105 { try await store.append(result(index), to: first.id) }
        var sessions = try await store.sessions()
        XCTAssertEqual(sessions[0].entries.count, BoundedSessionStore.maxEntriesPerSession)
        XCTAssertEqual(sessions[0].entries.first?.duration, 6)
        for _ in 0..<21 {
            try await store.startSession(ActivitySession(startedAt: start, appVersion: "1.0", macOSVersion: "14.0"))
        }
        sessions = try await store.sessions()
        XCTAssertEqual(sessions.count, BoundedSessionStore.maxSessions)
        XCTAssertFalse(sessions.contains(where: { $0.id == first.id }))
        let reloaded = try BoundedSessionStore(fileURL: url)
        let reloadedSessions = try await reloaded.sessions()
        XCTAssertEqual(reloadedSessions, sessions)
    }

    func testCorruptFileFallsBackSafelyAndCanBeReplacedAtomically() async throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("{corrupt".utf8).write(to: url)
        let store = try BoundedSessionStore(fileURL: url)
        let recovered = try await store.sessions()
        let warning = await store.loadWarning
        XCTAssertTrue(recovered.isEmpty)
        XCTAssertEqual(warning, .corruptFile)
        try await store.startSession(ActivitySession(startedAt: start, appVersion: "1.0", macOSVersion: "14.0"))
        let reloaded = try BoundedSessionStore(fileURL: url)
        let reloadedSessions = try await reloaded.sessions()
        XCTAssertEqual(reloadedSessions.count, 1)
    }

    func testWriteErrorDoesNotChangeInMemoryState() async throws {
        let url = temporaryURL()
        let directory = url.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try BoundedSessionStore(fileURL: url)
        let session = ActivitySession(startedAt: start, appVersion: "1.0", macOSVersion: "14.0")
        try await store.startSession(session)
        try FileManager.default.removeItem(at: url)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        do {
            try await store.append(result(), to: session.id)
            XCTFail("Expected write failure")
        } catch {
            XCTAssertEqual(error as? SessionStoreError, .ioFailure)
        }
        let sessions = try await store.sessions()
        XCTAssertEqual(sessions.count, 1)
        XCTAssertTrue(sessions[0].entries.isEmpty)
    }

    func testUnsupportedFormatIsNotOverwritten() async throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let original = Data("{\"formatVersion\":99,\"sessions\":[]}".utf8)
        try original.write(to: url)
        let store = try BoundedSessionStore(fileURL: url)
        do {
            _ = try await store.sessions()
            XCTFail("Expected unsupported format")
        } catch {
            XCTAssertEqual(error as? SessionStoreError, .unsupportedFormat(99))
        }
        XCTAssertEqual(try Data(contentsOf: url), original)
    }

    func testCancelledWriteDoesNotCreateFile() async throws {
        let url = temporaryURL()
        let store = try BoundedSessionStore(fileURL: url)
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            try await store.startSession(ActivitySession(startedAt: start, appVersion: "1.0", macOSVersion: "14.0"))
        }
        do {
            try await task.value
            XCTFail("Expected cancellation")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testPermissionDeniedIsDistinctFromOtherWriteErrors() async throws {
        let store = try BoundedSessionStore(fileURL: temporaryURL(), fileManager: DenyingFileManager())
        do {
            try await store.startSession(ActivitySession(startedAt: start, appVersion: "1.0", macOSVersion: "14.0"))
            XCTFail("Expected permission error")
        } catch {
            XCTAssertEqual(error as? SessionStoreError, .permissionDenied)
        }
        let sessions = try await store.sessions()
        XCTAssertTrue(sessions.isEmpty)
    }
}

private final class DenyingFileManager: FileManager {
    override func createDirectory(at url: URL, withIntermediateDirectories createIntermediates: Bool,
                                  attributes: [FileAttributeKey: Any]? = nil) throws {
        throw NSError(domain: NSCocoaErrorDomain, code: NSFileWriteNoPermissionError)
    }
}
