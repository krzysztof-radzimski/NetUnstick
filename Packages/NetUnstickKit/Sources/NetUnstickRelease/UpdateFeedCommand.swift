import Foundation
import CryptoKit
import NetUnstickCore
import NetUnstickNetwork

@main
struct UpdateFeedCommand {
    static func main() async {
        do { try await run() }
        catch {
            // Never print Keychain values or arbitrary process output.
            let code = (error as? AppUpdateError)?.rawValue ?? (error as? ProcessRunError)?.code ?? "release_preparation_failed"
            fputs("Przygotowanie aktualizacji nie powiodło się: \(code).\n", stderr)
            exit(1)
        }
    }

    private static func command(_ executable: String, _ arguments: [String]) async throws -> String {
        let result = try await BoundedProcess.run(executable: executable, arguments: arguments,
            environment: ["LC_ALL": "C", "LANG": "C"], timeout: 60, outputLimit: 65_536)
        guard result.exitStatus == 0 else { throw AppUpdateError.untrustedPackage }
        return result.stdout
    }

    private static func run() async throws {
        let args = Array(CommandLine.arguments.dropFirst())
        if args == ["--initialize-key"] {
            print(try UpdateSigningKey.load(create: true).publicKey.rawRepresentation.base64EncodedString())
            return
        }
        guard args.count == 2, args[0] == "--package" else {
            fputs("Użycie: Tools/BuildUpdateFeed.sh --package <notaryzowany.pkg>\n", stderr)
            exit(2)
        }
        let key = try UpdateSigningKey.load()
        guard key.publicKey.rawRepresentation.base64EncodedString() == AppUpdatePolicy.signingPublicKey else {
            throw AppUpdateError.invalidSignature
        }
        let fileManager = FileManager.default
        let package = URL(fileURLWithPath: args[1]).standardizedFileURL
        guard package.pathExtension == "pkg", !package.lastPathComponent.contains("UNNOTARIZED") else {
            throw AppUpdateError.invalidPackage
        }
        let size = try package.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size > 0, size <= AppUpdatePolicy.maximumPackageBytes else { throw AppUpdateError.invalidPackage }
        _ = try await command("/usr/bin/xcrun", ["stapler", "validate", package.path])
        _ = try await command("/usr/sbin/spctl", ["--assess", "--type", "install", package.path])
        let work = fileManager.temporaryDirectory.appendingPathComponent("NetUnstick-feed-\(UUID().uuidString)")
        try fileManager.createDirectory(at: work, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? fileManager.removeItem(at: work) }
        let expanded = work.appendingPathComponent("expanded")
        _ = try await command("/usr/sbin/pkgutil", ["--expand-full", package.path, expanded.path])
        let app = expanded.appendingPathComponent("NetUnstick.pkg/Payload/NetUnstick.app")
        let architecture = try await command("/usr/bin/lipo", ["-archs", app.appendingPathComponent("Contents/MacOS/NetUnstick").path])
        guard architecture.trimmingCharacters(in: .whitespacesAndNewlines) == "arm64" else {
            throw AppUpdateError.incompatible
        }
        let infoData = try Data(contentsOf: app.appendingPathComponent("Contents/Info.plist"))
        guard let info = try PropertyListSerialization.propertyList(from: infoData, format: nil) as? [String: Any],
              let version = info["CFBundleShortVersionString"] as? String,
              let buildString = info["CFBundleVersion"] as? String, let build = Int(buildString),
              let minimum = info["LSMinimumSystemVersion"] as? String,
              info["CFBundleIdentifier"] as? String == "org.netunstick.NetUnstick" else {
            throw AppUpdateError.invalidPackage
        }
        let data = try Data(contentsOf: package, options: .mappedIfSafe)
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let release = AppUpdateRelease(version: version, build: build, minimumSystemVersion: minimum,
            packageURL: AppUpdatePolicy.feedURL.deletingLastPathComponent().appendingPathComponent(package.lastPathComponent),
            byteCount: size, sha256: digest)
        try await UpdatePackageVerifier().verify(package, release: release)
        // Reuse the release bundle checks, including the helper and its XPC identity policy.
        _ = try await command("/bin/zsh", ["NetUnstick/TestSupport/check-helper-bundle.sh", app.path, "--require-developer-id"])
        let manifest = AppUpdateManifest(release: release,
            signature: try key.signature(for: release.signingData()).base64EncodedString())
        _ = try manifest.verified(publicKey: key.publicKey.rawRepresentation)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let output = URL(fileURLWithPath: fileManager.currentDirectoryPath)
            .appendingPathComponent("Artifacts/UpdatePublication/public/NetUnstick/updates")
        try fileManager.createDirectory(at: output, withIntermediateDirectories: true)
        let destination = output.appendingPathComponent(package.lastPathComponent)
        if fileManager.fileExists(atPath: destination.path) {
            guard try Data(contentsOf: destination, options: .mappedIfSafe) == data else {
                throw AppUpdateError.invalidPackage // Published versioned URLs are immutable.
            }
        } else { try data.write(to: destination, options: .atomic) }
        try (digest + "  " + package.lastPathComponent + "\n").write(
            to: destination.appendingPathExtension("sha256"), atomically: true, encoding: .utf8)
        try encoder.encode(manifest).write(to: output.appendingPathComponent("latest.json"), options: .atomic)
        let publication = output.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let root = URL(fileURLWithPath: fileManager.currentDirectoryPath)
        for (source, target) in [("Distribution/Updates/headers.fragment", "headers.fragment"),
                                 ("docs/updates-itorg.md", "README.md")] {
            try Data(contentsOf: root.appendingPathComponent(source)).write(to: publication.appendingPathComponent(target), options: .atomic)
        }
        for language in ["pl", "en", "es"] {
            let folder = publication.appendingPathComponent("privacy-content/\(language)")
            try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data(contentsOf: root.appendingPathComponent("Distribution/Website/\(language)/privacy.html"))
                .write(to: folder.appendingPathComponent("privacy.html"), options: .atomic)
        }
        print("Przygotowano podpisany latest.json i PKG \(version) (\(build)) w \(output.path)")
    }
}
