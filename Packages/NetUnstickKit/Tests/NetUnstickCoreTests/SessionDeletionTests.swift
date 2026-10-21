import Foundation
import XCTest
@testable import NetUnstickCore

private final class DeniedDeletionFileManager: FileManager, @unchecked Sendable {
    override func removeItem(at URL: URL) throws {
        throw NSError(domain: NSCocoaErrorDomain, code: NSFileWriteNoPermissionError)
    }
}

final class SessionDeletionTests: XCTestCase {
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    func testEraseDeletesOnlyHistoryAndRemainsEmptyAfterReopening() async throws {
        let root = try directory()
        let url = root.appendingPathComponent("sessions.json")
        let exported = root.appendingPathComponent("export.txt")
        try Data("independent export".utf8).write(to: exported)
        let store = try BoundedSessionStore(fileURL: url)
        try await store.startSession(.init(startedAt: Date(), appVersion: "1", macOSVersion: "14"))
        try await store.removeAll()
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        XCTAssertEqual(try String(contentsOf: exported, encoding: .utf8), "independent export")
        let reopened = try BoundedSessionStore(fileURL: url)
        let sessions = try await reopened.sessions()
        XCTAssertTrue(sessions.isEmpty)
        try await reopened.startSession(.init(startedAt: Date(), appVersion: "1", macOSVersion: "14"))
        let newSessions = try await reopened.sessions()
        XCTAssertEqual(newSessions.count, 1)
    }

    func testExplicitEraseCanRemoveUnknownFormatWithoutLoadingOrOverwritingIt() async throws {
        let url = try directory().appendingPathComponent("sessions.json")
        try Data(#"{"formatVersion":999,"sessions":[]}"#.utf8).write(to: url)
        let store = try BoundedSessionStore(fileURL: url)
        do { _ = try await store.sessions(); XCTFail("Unknown format must remain protected from ordinary writes") }
        catch { XCTAssertEqual(error as? SessionStoreError, .unsupportedFormat(999)) }
        try await store.removeAll()
        let sessions = try await store.sessions()
        XCTAssertTrue(sessions.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testPermissionFailurePreservesFileAndInMemorySessions() async throws {
        let url = try directory().appendingPathComponent("sessions.json")
        let store = try BoundedSessionStore(fileURL: url, fileManager: DeniedDeletionFileManager())
        let session = ActivitySession(startedAt: Date(), appVersion: "1", macOSVersion: "14")
        try await store.startSession(session)
        let before = try Data(contentsOf: url)
        do { try await store.removeAll(); XCTFail("Expected permission failure") }
        catch { XCTAssertEqual(error as? SessionStoreError, .permissionDenied) }
        XCTAssertEqual(try Data(contentsOf: url), before)
        let sessions = try await store.sessions()
        XCTAssertEqual(sessions.map(\.id), [session.id])
    }

    func testCancellationBeforeErasePreservesHistory() async throws {
        let url = try directory().appendingPathComponent("sessions.json")
        let store = try BoundedSessionStore(fileURL: url)
        try await store.startSession(.init(startedAt: Date(), appVersion: "1", macOSVersion: "14"))
        let cancelled = await Task {
            withUnsafeCurrentTask { $0?.cancel() }
            do { try await store.removeAll(); return false }
            catch is CancellationError { return true }
            catch { return false }
        }.value
        XCTAssertTrue(cancelled)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        let sessions = try await store.sessions()
        XCTAssertEqual(sessions.count, 1)
    }
}
