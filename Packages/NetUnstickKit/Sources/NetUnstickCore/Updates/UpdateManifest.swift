import Foundation
import CryptoKit

public enum AppUpdateError: String, Error, Sendable {
    case unavailable, invalidManifest, invalidSignature, incompatible, invalidPackage, untrustedPackage
}

/// Only a verified manifest may authorize a download. All fields below are signed.
public struct AppUpdateRelease: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let bundleIdentifier: String
    public let version: String
    public let build: Int
    public let minimumSystemVersion: String
    public let architecture: String
    public let packageURL: URL
    public let byteCount: Int
    public let sha256: String

    public init(schemaVersion: Int = 1, bundleIdentifier: String = "org.netunstick.NetUnstick",
                version: String, build: Int, minimumSystemVersion: String = "14.0",
                architecture: String = "arm64", packageURL: URL, byteCount: Int, sha256: String) {
        self.schemaVersion = schemaVersion; self.bundleIdentifier = bundleIdentifier
        self.version = version; self.build = build; self.minimumSystemVersion = minimumSystemVersion
        self.architecture = architecture; self.packageURL = packageURL
        self.byteCount = byteCount; self.sha256 = sha256
    }

    public func signingData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }
}

public struct AppUpdateManifest: Codable, Sendable {
    public let release: AppUpdateRelease
    public let signature: String

    public init(release: AppUpdateRelease, signature: String) {
        self.release = release; self.signature = signature
    }

    public func verified(publicKey: Data) throws -> AppUpdateRelease {
        guard let signature = Data(base64Encoded: signature), signature.count == 64,
              let key = try? Curve25519.Signing.PublicKey(rawRepresentation: publicKey),
              key.isValidSignature(signature, for: try release.signingData()) else {
            throw AppUpdateError.invalidSignature
        }
        return release
    }
}

public enum AppUpdatePolicy {
    public static let feedURL = URL(string: "https://itorg.pl/NetUnstick/updates/latest.json")!
    public static let maximumPackageBytes = 25 * 1024 * 1024
    public static let maximumManifestBytes = 16 * 1024
    // Public Ed25519 key only. Its private counterpart stays in the release Mac's Keychain.
    public static let signingPublicKey = "lzrrUsSJkYIWAsQFIEj4pNJjv7EINiM2VBESKZTjIIw="

    public static func allows(_ url: URL) -> Bool {
        guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              parts.scheme == "https", parts.host == "itorg.pl", parts.port == nil || parts.port == 443,
              parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil,
              parts.percentEncodedPath == parts.path,
              parts.path.hasPrefix("/NetUnstick/updates/"),
              !parts.path.split(separator: "/").contains(where: { $0 == "." || $0 == ".." }) else { return false }
        return true
    }

    public static func versionComponents(_ value: String) -> [Int]? {
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...3).contains(parts.count), parts.allSatisfy({
            !$0.isEmpty && $0.count <= 6 && $0.utf8.allSatisfy { (48...57).contains($0) }
        }) else { return nil }
        return parts.map { Int($0)! } + Array(repeating: 0, count: 3 - parts.count)
    }

    public static func validate(_ release: AppUpdateRelease) throws {
        guard release.schemaVersion == 1, release.bundleIdentifier == "org.netunstick.NetUnstick",
              versionComponents(release.version)?.count == 3, release.version.split(separator: ".").count == 3,
              release.build > 0, release.build <= 2_147_483_647,
              versionComponents(release.minimumSystemVersion) != nil,
              release.architecture == "arm64", release.byteCount > 0, release.byteCount <= maximumPackageBytes,
              release.sha256.count == 64, release.sha256.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
              allows(release.packageURL),
              release.packageURL.lastPathComponent == "NetUnstick-\(release.version)-\(release.build)-arm64.pkg" else {
            throw AppUpdateError.invalidManifest
        }
    }

    public static func isNewer(_ release: AppUpdateRelease, currentVersion: String, currentBuild: Int,
                               systemVersion: String, architecture: String = "arm64") throws -> Bool {
        try validate(release)
        guard let current = versionComponents(currentVersion), currentBuild > 0,
              let system = versionComponents(systemVersion),
              let minimum = versionComponents(release.minimumSystemVersion),
              architecture == release.architecture else { throw AppUpdateError.incompatible }
        guard !system.lexicographicallyPrecedes(minimum) else { throw AppUpdateError.incompatible }
        let proposed = versionComponents(release.version)!
        // Both the public version and monotonic build protect against downgrades.
        return !proposed.lexicographicallyPrecedes(current) && release.build > currentBuild
    }
}
