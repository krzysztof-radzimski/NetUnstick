import XCTest
import CryptoKit
import NetUnstickCore
@testable import NetUnstickNetwork

private final class UpdateURLProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    private static var responses: [String: (Int, Data)] = [:]
    static func set(_ url: URL, status: Int = 200, data: Data) {
        lock.lock(); defer { lock.unlock() }; responses[url.absoluteString] = (status, data)
    }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock(); let value = Self.responses[request.url!.absoluteString]; Self.lock.unlock()
        let (status, data) = value ?? (404, Data())
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

final class AppUpdateClientTests: XCTestCase {
    private func client(key: Data = Data(repeating: 0, count: 32), directory: URL? = nil) -> AppUpdateClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [UpdateURLProtocol.self]
        return AppUpdateClient(session: URLSession(configuration: configuration), publicKey: key, directory: directory)
    }

    private func release(size: Int = 3) -> AppUpdateRelease {
        AppUpdateRelease(version: "0.4.0", build: 15,
            packageURL: URL(string: "https://itorg.pl/NetUnstick/updates/NetUnstick-0.4.0-15-arm64.pkg")!,
            byteCount: size, sha256: String(repeating: "a", count: 64))
    }

    func testCheckUsesVerifiedFeedAndRecognizesCurrentVersion() async throws {
        let key = Curve25519.Signing.PrivateKey()
        let release = release()
        let manifest = AppUpdateManifest(release: release, signature: try key.signature(for: release.signingData()).base64EncodedString())
        UpdateURLProtocol.set(AppUpdatePolicy.feedURL, data: try JSONEncoder().encode(manifest))
        let service = client(key: key.publicKey.rawRepresentation)
        let next = try await service.check(currentVersion: "0.3.1", currentBuild: 14, systemVersion: "14.0")
        XCTAssertEqual(next, release)
        let current = try await service.check(currentVersion: "0.4.0", currentBuild: 15, systemVersion: "14.0")
        XCTAssertNil(current)
    }

    func testOfflineMissingMalformedAndUnsignedFeedsAreRejected() async {
        for (status, data) in [(404, Data()), (500, Data()), (200, Data("<html>not a feed</html>".utf8)),
                               (200, Data(repeating: 65, count: AppUpdatePolicy.maximumManifestBytes + 1))] {
            UpdateURLProtocol.set(AppUpdatePolicy.feedURL, status: status, data: data)
            do { _ = try await client().check(currentVersion: "0.3.1", currentBuild: 14, systemVersion: "14.0"); XCTFail("Nieprawidłowy feed zaakceptowany") }
            catch {}
        }
    }

    func testTruncatedAndOversizedDownloadsRemovePartialFiles() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let release = release()
        let service = client(directory: directory)
        for data in [Data([1]), Data([1, 2, 3, 4])] {
            UpdateURLProtocol.set(release.packageURL, data: data)
            do { _ = try await service.download(release) { _ in }; XCTFail("Błędny rozmiar zaakceptowany") }
            catch {}
            XCTAssertEqual((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? [], [])
        }
    }

    func testSuccessfulDownloadAndHashMismatchCannotPassVerification() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let release = release()
        UpdateURLProtocol.set(release.packageURL, data: Data([1, 2, 3]))
        let file = try await client(directory: directory).download(release) { _ in }
        XCTAssertEqual(try Data(contentsOf: file), Data([1, 2, 3]))
        do { try await UpdatePackageVerifier().verify(file, release: release); XCTFail("Niezgodny SHA-256 zaakceptowany") }
        catch { XCTAssertEqual(error as? AppUpdateError, .invalidPackage) }
    }

    func testPreparedPublicationWithRealNotarizedPackage() async throws {
        guard let root = ProcessInfo.processInfo.environment["NETUNSTICK_UPDATE_PUBLICATION"] else {
            throw XCTSkip("Wymaga lokalnego, przygotowanego wydania PKG; nie instaluje aplikacji.")
        }
        let publication = URL(fileURLWithPath: root)
        let feed = try Data(contentsOf: publication.appendingPathComponent("latest.json"))
        let manifest = try JSONDecoder().decode(AppUpdateManifest.self, from: feed)
        let release = try manifest.verified(publicKey: Data(base64Encoded: AppUpdatePolicy.signingPublicKey)!)
        let data = try Data(contentsOf: publication.appendingPathComponent(release.packageURL.lastPathComponent))
        UpdateURLProtocol.set(AppUpdatePolicy.feedURL, data: feed)
        UpdateURLProtocol.set(release.packageURL, data: data)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let service = client(key: Data(base64Encoded: AppUpdatePolicy.signingPublicKey)!, directory: directory)
        let available = try await service.check(currentVersion: "0.3.0", currentBuild: 13, systemVersion: "14.0")
        XCTAssertEqual(available, release)
        let package = try await service.download(release) { _ in }
        try await UpdatePackageVerifier().verify(package, release: release)
        XCTAssertEqual(try Data(contentsOf: package), data)
    }
}
