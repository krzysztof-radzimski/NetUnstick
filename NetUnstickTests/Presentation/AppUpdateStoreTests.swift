import XCTest
import NetUnstickCore
import NetUnstickNetwork
@testable import NetUnstick

private actor UpdateServiceStub: AppUpdateServing {
    let value: AppUpdateRelease?
    let slow: Bool
    private(set) var calls = 0
    init(_ value: AppUpdateRelease?, slow: Bool = false) { self.value = value; self.slow = slow }
    func check(currentVersion: String, currentBuild: Int, systemVersion: String) async throws -> AppUpdateRelease? {
        calls += 1
        if slow { try await Task.sleep(for: .seconds(30)) }
        return value
    }
    func download(_ release: AppUpdateRelease, progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        progress(1)
        return URL(fileURLWithPath: "/tmp/netunstick-update-test.pkg")
    }
}

private actor VerificationStub {
    var reject = false
    private(set) var calls = 0
    func setReject() { reject = true }
    func verify() throws { calls += 1; if reject { throw AppUpdateError.invalidPackage } }
}

@MainActor
final class AppUpdateStoreTests: XCTestCase {
    private func release() -> AppUpdateRelease {
        AppUpdateRelease(version: "0.4.0", build: 15,
            packageURL: URL(string: "https://itorg.pl/NetUnstick/updates/NetUnstick-0.4.0-15-arm64.pkg")!,
            byteCount: 3, sha256: String(repeating: "a", count: 64))
    }

    func testCheckAndDownloadNeverOpenInstallerAutomatically() async throws {
        let name = "NetUnstick.UpdateTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let validator = VerificationStub()
        var opened = 0
        let store = AppUpdateStore(client: UpdateServiceStub(release()), defaults: defaults,
            version: "0.3.1", build: 14, verify: { _, _ in try await validator.verify() },
            openInstaller: { _ in opened += 1 })
        await store.checkForUpdates()?.value
        XCTAssertEqual(store.phase, .available)
        await store.download()?.value
        XCTAssertEqual(store.phase, .ready)
        XCTAssertEqual(opened, 0)
        await store.install(mayInstall: { false })?.value
        XCTAssertEqual(opened, 0)
        await store.install(mayInstall: { true })?.value
        XCTAssertEqual(opened, 1)
        XCTAssertEqual(store.phase, .installerOpened)
        let verifications = await validator.calls
        XCTAssertEqual(verifications, 2)
    }

    func testCacheTamperingBlocksInstallation() async {
        let validator = VerificationStub()
        var opened = false
        let store = AppUpdateStore(client: UpdateServiceStub(release()),
            version: "0.3.1", build: 14, verify: { _, _ in try await validator.verify() },
            openInstaller: { _ in opened = true })
        await store.checkForUpdates()?.value
        await store.download()?.value
        await validator.setReject()
        await store.install(mayInstall: { true })?.value
        XCTAssertFalse(opened)
        XCTAssertEqual(store.phase, .rejected)
    }

    func testCancellationDoesNotPublishALateCheckResult() async {
        let store = AppUpdateStore(client: UpdateServiceStub(release(), slow: true), version: "0.3.1", build: 14)
        let checking = store.checkForUpdates()
        XCTAssertNil(store.checkForUpdates())
        store.cancel()
        await checking?.value
        XCTAssertEqual(store.phase, .idle)
        XCTAssertNil(store.release)
    }

    func testStartupPreferencePersistsAndManualCheckStillWorks() async {
        let name = "NetUnstick.UpdateTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let store = AppUpdateStore(client: UpdateServiceStub(nil), defaults: defaults, version: "0.3.1", build: 14)
        XCTAssertTrue(store.checksAtStartup)
        store.checksAtStartup = false
        XCTAssertFalse(defaults.bool(forKey: "updates.checkAtStartup"))
        await store.checkForUpdates()?.value
        XCTAssertEqual(store.phase, .current)
    }
}
