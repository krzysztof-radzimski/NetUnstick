import XCTest
import CryptoKit
@testable import NetUnstickCore

final class AppUpdateManifestTests: XCTestCase {
    private func release(version: String = "0.4.0", build: Int = 15, minimum: String = "14.0",
                         url: String = "https://itorg.pl/NetUnstick/updates/NetUnstick-0.4.0-15-arm64.pkg",
                         size: Int = 1024, hash: String = String(repeating: "a", count: 64)) -> AppUpdateRelease {
        AppUpdateRelease(version: version, build: build, minimumSystemVersion: minimum,
                         packageURL: URL(string: url)!, byteCount: size, sha256: hash)
    }

    func testSignedManifestRoundTripsAndRejectsChanges() throws {
        let key = Curve25519.Signing.PrivateKey()
        let original = release()
        let signed = AppUpdateManifest(release: original, signature: try key.signature(for: original.signingData()).base64EncodedString())
        let decoded = try JSONDecoder().decode(AppUpdateManifest.self, from: JSONEncoder().encode(signed))
        XCTAssertEqual(try decoded.verified(publicKey: key.publicKey.rawRepresentation), original)
        let changed = AppUpdateManifest(release: release(size: 2048), signature: signed.signature)
        XCTAssertThrowsError(try changed.verified(publicKey: key.publicKey.rawRepresentation))
        XCTAssertThrowsError(try signed.verified(publicKey: Curve25519.Signing.PrivateKey().publicKey.rawRepresentation))
        XCTAssertThrowsError(try AppUpdateManifest(release: original, signature: "broken").verified(publicKey: key.publicKey.rawRepresentation))
    }

    func testMonotonicBuildsAndVersionsPreventDowngrades() throws {
        let next = release()
        XCTAssertTrue(try AppUpdatePolicy.isNewer(next, currentVersion: "0.3.1", currentBuild: 14, systemVersion: "14.0"))
        XCTAssertFalse(try AppUpdatePolicy.isNewer(next, currentVersion: "0.4.0", currentBuild: 15, systemVersion: "14.0"))
        XCTAssertFalse(try AppUpdatePolicy.isNewer(next, currentVersion: "0.4.0", currentBuild: 16, systemVersion: "14.0"))
        XCTAssertFalse(try AppUpdatePolicy.isNewer(next, currentVersion: "0.5.0", currentBuild: 14, systemVersion: "14.0"))
        XCTAssertTrue(try AppUpdatePolicy.isNewer(next, currentVersion: "0.4.0", currentBuild: 14, systemVersion: "14.0"))
    }

    func testCompatibilityAndMalformedVersions() throws {
        XCTAssertThrowsError(try AppUpdatePolicy.isNewer(release(), currentVersion: "0.3.1", currentBuild: 14,
                                                        systemVersion: "13.6"))
        XCTAssertThrowsError(try AppUpdatePolicy.isNewer(release(), currentVersion: "0.3.1", currentBuild: 14,
                                                        systemVersion: "14.0", architecture: "x86_64"))
        for value in ["", "1..2", "1.2.3.4", "-1", "1-beta", "999999999999999999999", "١.٢.٣"] {
            XCTAssertNil(AppUpdatePolicy.versionComponents(value), value)
        }
        XCTAssertEqual(AppUpdatePolicy.versionComponents("14"), [14, 0, 0])
    }

    func testOnlyPublisherHTTPSPathsAreAllowed() {
        XCTAssertTrue(AppUpdatePolicy.allows(AppUpdatePolicy.feedURL))
        for value in ["http://itorg.pl/NetUnstick/updates/latest.json", "https://evil.test/NetUnstick/updates/latest.json",
                      "https://itorg.pl.evil.test/NetUnstick/updates/latest.json", "https://user@itorg.pl/NetUnstick/updates/latest.json",
                      "https://itorg.pl:8443/NetUnstick/updates/latest.json", "https://itorg.pl/NetUnstick/updates/../other.pkg",
                      "https://itorg.pl/NetUnstick/updates/%2e%2e/other.pkg", "https://itorg.pl/other/latest.json",
                      "https://itorg.pl/NetUnstick/updates/latest.json?token=secret", "file:///tmp/update.pkg"] {
            XCTAssertFalse(AppUpdatePolicy.allows(URL(string: value)!), value)
        }
    }

    func testReleaseLimitsAndExpectedFilename() {
        for bad in [release(size: 0), release(size: AppUpdatePolicy.maximumPackageBytes + 1),
                    release(hash: "invalid"), release(url: "https://itorg.pl/NetUnstick/updates/another-app.pkg"),
                    release(version: "999999999.1.0"), release(build: -1)] {
            XCTAssertThrowsError(try AppUpdatePolicy.validate(bad))
        }
    }
}
