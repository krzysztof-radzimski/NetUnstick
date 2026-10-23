import Foundation
import CryptoKit
import NetUnstickCore

/// Read-only checks. This type never installs software or invokes the network repair helper.
public struct UpdatePackageVerifier: Sendable {
    public init() {}

    public func verify(_ package: URL, release: AppUpdateRelease) async throws {
        try AppUpdatePolicy.validate(release)
        let handle = try FileHandle(forReadingFrom: package)
        defer { try? handle.close() }
        var hash = SHA256()
        var size = 0
        while let chunk = try handle.read(upToCount: 65_536), !chunk.isEmpty {
            try Task.checkCancellation()
            size += chunk.count
            guard size <= release.byteCount else { throw AppUpdateError.invalidPackage }
            hash.update(data: chunk)
        }
        guard size == release.byteCount,
              hash.finalize().map({ String(format: "%02x", $0) }).joined() == release.sha256 else {
            throw AppUpdateError.invalidPackage
        }
        // pkgutil verifies the flat PKG signature and certificate chain. Pin the publisher's
        // installer identity as well; an arbitrary other notarized application is insufficient.
        let signature = try await BoundedProcess.run(executable: "/usr/sbin/pkgutil",
            arguments: ["--check-signature", package.path], environment: ["LC_ALL": "C", "LANG": "C"],
            timeout: 30, outputLimit: 32_768)
        guard signature.exitStatus == 0,
              signature.stdout.split(separator: "\n").contains(where: {
                  $0.trimmingCharacters(in: .whitespaces) == "1. Developer ID Installer: Krzysztof Radzimski (UGL4ZTH3C6)"
              }) else {
            throw AppUpdateError.untrustedPackage
        }
        let assessment = try await BoundedProcess.run(executable: "/usr/sbin/spctl",
            arguments: ["--assess", "--type", "install", "--verbose=2", package.path],
            environment: ["LC_ALL": "C", "LANG": "C"], timeout: 45, outputLimit: 32_768)
        guard assessment.exitStatus == 0,
              (assessment.stdout + assessment.stderr).contains("source=Notarized Developer ID") else {
            throw AppUpdateError.untrustedPackage
        }
    }
}
