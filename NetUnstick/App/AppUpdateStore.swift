import AppKit
import SwiftUI
import OSLog
import NetUnstickCore
import NetUnstickNetwork

@MainActor
final class AppUpdateStore: ObservableObject {
    enum Phase: Equatable { case idle, checking, current, available, downloading, verifying, ready, openingInstaller, installerOpened, failed, rejected, incompatible }
    @Published private(set) var phase: Phase = .idle
    @Published private(set) var release: AppUpdateRelease?
    @Published private(set) var progress = 0.0
    @Published var checksAtStartup: Bool {
        didSet { defaults.set(checksAtStartup, forKey: "updates.checkAtStartup") }
    }
    private let defaults: UserDefaults
    private let client: any AppUpdateServing
    private let currentVersion: String
    private let currentBuild: Int
    private let systemVersion: String
    private let verify: @Sendable (URL, AppUpdateRelease) async throws -> Void
    private let openInstaller: @MainActor (URL) async throws -> Void
    private var package: URL?
    private var task: Task<Void, Never>?
    private var generation = UUID()
    private var started = false
    private let logger = Logger(subsystem: "org.netunstick.NetUnstick", category: "Updates")

    init(client: any AppUpdateServing = AppUpdateClient(), defaults: UserDefaults = .standard,
         version: String? = nil, build: Int? = nil, systemVersion: String? = nil,
         verify: @escaping @Sendable (URL, AppUpdateRelease) async throws -> Void = {
             try await UpdatePackageVerifier().verify($0, release: $1)
         },
         openInstaller: @escaping @MainActor (URL) async throws -> Void = { package in
             let configuration = NSWorkspace.OpenConfiguration()
             _ = try await NSWorkspace.shared.open([package],
                 withApplicationAt: URL(fileURLWithPath: "/System/Library/CoreServices/Installer.app"),
                 configuration: configuration)
         }) {
        self.client = client; self.defaults = defaults
        currentVersion = version ?? Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        currentBuild = build ?? Int(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "") ?? 0
        let os = ProcessInfo.processInfo.operatingSystemVersion
        self.systemVersion = systemVersion ?? "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)"
        self.verify = verify; self.openInstaller = openInstaller
        checksAtStartup = defaults.object(forKey: "updates.checkAtStartup") as? Bool ?? true
    }

    var isBusy: Bool { [.checking, .downloading, .verifying, .openingInstaller].contains(phase) }
    var hasUpdate: Bool { release != nil && [.available, .downloading, .verifying, .ready].contains(phase) }

    func checkAtStartup() {
        guard !started else { return }; started = true
        #if DEBUG
        // Presentation scenarios and hosted unit tests never contact the public feed.
        if NSClassFromString("XCTestCase") != nil || ProcessInfo.processInfo.arguments.contains(where: {
            $0.hasPrefix("--scenario=") || $0.hasPrefix("--integration-scenario=")
        }) { return }
        #endif
        if checksAtStartup { checkForUpdates() }
    }

    @discardableResult func checkForUpdates() -> Task<Void, Never>? {
        guard !isBusy, phase != .installerOpened else { return nil }
        generation = UUID(); let id = generation
        phase = .checking; release = nil; package = nil
        task = Task {
            do {
                let result = try await client.check(currentVersion: currentVersion, currentBuild: currentBuild, systemVersion: systemVersion)
                try Task.checkCancellation()
                guard generation == id else { return }
                release = result; phase = result == nil ? .current : .available
            } catch { fail(error, generation: id) }
        }
        return task
    }

    @discardableResult func download() -> Task<Void, Never>? {
        guard !isBusy, phase == .available, let release else { return nil }
        generation = UUID(); let id = generation
        phase = .downloading; progress = 0
        task = Task {
            var downloaded: URL?
            do {
                let file = try await client.download(release) { [weak self] value in
                    Task { @MainActor in
                        guard let self, self.generation == id, self.phase == .downloading else { return }
                        self.progress = min(1, max(0, value))
                    }
                }
                downloaded = file
                try Task.checkCancellation()
                guard generation == id else { throw CancellationError() }
                phase = .verifying
                try await verify(file, release)
                try Task.checkCancellation()
                guard generation == id else { throw CancellationError() }
                package = file; phase = .ready
            } catch {
                if let downloaded, downloaded.deletingLastPathComponent().lastPathComponent.hasPrefix("download-") {
                    try? FileManager.default.removeItem(at: downloaded.deletingLastPathComponent())
                }
                fail(error, generation: id)
            }
        }
        return task
    }

    @discardableResult func install(mayInstall: @escaping @MainActor () -> Bool) -> Task<Void, Never>? {
        guard phase == .ready, let package, let release, mayInstall() else { return nil }
        generation = UUID(); let id = generation; phase = .verifying
        task = Task {
            do {
                // Recheck the cached file immediately before handing it to the system Installer.
                try await verify(package, release)
                try Task.checkCancellation()
                guard generation == id else { return }
                guard mayInstall() else { phase = .ready; return }
                phase = .openingInstaller
                try await openInstaller(package)
                guard generation == id else { return }
                phase = .installerOpened
            } catch { fail(error, generation: id) }
        }
        return task
    }

    func cancel() {
        guard phase != .openingInstaller else { return }
        generation = UUID(); task?.cancel(); task = nil
        phase = package != nil ? .ready : release != nil ? .available : .idle
    }

    private func fail(_ error: Error, generation id: UUID) {
        guard generation == id else { return }
        if error is CancellationError || (error as? URLError)?.code == .cancelled {
            phase = release == nil ? .idle : .available
            return
        }
        let failure = error as? AppUpdateError
        let code = failure?.rawValue ?? "request_failed"
        logger.error("update_failed code=\(code, privacy: .public)")
        if failure == .incompatible { phase = .incompatible }
        else if let failure, [.invalidSignature, .invalidManifest, .invalidPackage, .untrustedPackage].contains(failure) {
            phase = .rejected
        } else { phase = .failed }
    }
}
