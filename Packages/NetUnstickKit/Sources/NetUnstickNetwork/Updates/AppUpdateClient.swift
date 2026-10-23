import Foundation
import NetUnstickCore

public protocol AppUpdateServing: Sendable {
    func check(currentVersion: String, currentBuild: Int, systemVersion: String) async throws -> AppUpdateRelease?
    func download(_ release: AppUpdateRelease, progress: @escaping @Sendable (Double) -> Void) async throws -> URL
}

private final class UpdateRedirectPolicy: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(request.url.map(AppUpdatePolicy.allows) == true ? request : nil)
    }
}

/// Dedicated ephemeral HTTP session: no cookies, credentials, diagnostics or installation IDs.
public actor AppUpdateClient: AppUpdateServing {
    private let session: URLSession
    private let publicKey: Data
    private let directory: URL
    private let redirects = UpdateRedirectPolicy()

    public init(session: URLSession? = nil, publicKey: Data? = nil, directory: URL? = nil) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 180
        self.session = session ?? URLSession(configuration: configuration)
        self.publicKey = publicKey ?? Data(base64Encoded: AppUpdatePolicy.signingPublicKey)!
        self.directory = directory ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("NetUnstick/Updates", isDirectory: true)
    }

    private func request(_ url: URL, limit: Int) async throws -> URLSession.AsyncBytes {
        guard AppUpdatePolicy.allows(url) else { throw AppUpdateError.invalidManifest }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: 20)
        request.setValue("NetUnstick", forHTTPHeaderField: "User-Agent")
        let (bytes, response) = try await session.bytes(for: request, delegate: redirects)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
              http.url.map(AppUpdatePolicy.allows) == true,
              response.expectedContentLength <= limit else {
            bytes.task.cancel()
            throw AppUpdateError.unavailable
        }
        return bytes
    }

    public func check(currentVersion: String, currentBuild: Int, systemVersion: String) async throws -> AppUpdateRelease? {
        let bytes = try await request(AppUpdatePolicy.feedURL, limit: AppUpdatePolicy.maximumManifestBytes)
        defer { bytes.task.cancel() }
        var data = Data()
        for try await byte in bytes {
            try Task.checkCancellation()
            guard data.count < AppUpdatePolicy.maximumManifestBytes else { throw AppUpdateError.invalidManifest }
            data.append(byte)
        }
        guard let manifest = try? JSONDecoder().decode(AppUpdateManifest.self, from: data) else {
            throw AppUpdateError.invalidManifest
        }
        let release = try manifest.verified(publicKey: publicKey)
        return try AppUpdatePolicy.isNewer(release, currentVersion: currentVersion, currentBuild: currentBuild,
            systemVersion: systemVersion) ? release : nil
    }

    public func download(_ release: AppUpdateRelease, progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        try AppUpdatePolicy.validate(release)
        let bytes = try await request(release.packageURL, limit: release.byteCount)
        defer { bytes.task.cancel() }
        let manager = FileManager.default
        try manager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        // Remove only this updater's expired folders, never downloaded user reports.
        for old in (try? manager.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [] {
            if old.lastPathComponent.hasPrefix("download-"),
               let date = try? old.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
               Date().timeIntervalSince(date) > 7 * 86400 { try? manager.removeItem(at: old) }
        }
        let folder = directory.appendingPathComponent("download-\(UUID().uuidString)", isDirectory: true)
        try manager.createDirectory(at: folder, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let destination = folder.appendingPathComponent(release.packageURL.lastPathComponent)
        guard manager.createFile(atPath: destination.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
            try? manager.removeItem(at: folder)
            throw AppUpdateError.invalidPackage
        }
        do {
            let handle = try FileHandle(forWritingTo: destination)
            defer { try? handle.close() }
            var buffer = Data(capacity: 65_536)
            var count = 0
            var lastPercent = -1
            for try await byte in bytes {
                try Task.checkCancellation()
                guard count < release.byteCount else { throw AppUpdateError.invalidPackage }
                count += 1; buffer.append(byte)
                if buffer.count == 65_536 {
                    try handle.write(contentsOf: buffer); buffer.removeAll(keepingCapacity: true)
                    let percent = count * 100 / release.byteCount
                    if percent != lastPercent { lastPercent = percent; progress(Double(count) / Double(release.byteCount)) }
                }
            }
            guard count == release.byteCount else { throw AppUpdateError.invalidPackage }
            try handle.write(contentsOf: buffer)
            try handle.synchronize()
            progress(1)
            return destination
        } catch {
            try? manager.removeItem(at: folder)
            throw error
        }
    }
}
