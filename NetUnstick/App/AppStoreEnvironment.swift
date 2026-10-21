#if APP_STORE
import Foundation
import os
import NetUnstickCore
import NetUnstickStoreNetwork

/// The App Store composition has no helper, repair executor, system collector or subprocesses.
/// It measures only connectivity available to this sandbox, never the host's VPN configuration.
@MainActor final class AppStoreEnvironment: PresentationService {
    let scenario = "app-store"
    let supportsRepairs = false
    let helper = HelperPresentationState.unavailable
    private let sessionsStore: BoundedSessionStore
    private let probes: any StoreNetworkProbing
    private let bonjour: any BonjourBrowsing
    private let logger = Logger(subsystem: "org.netunstick.NetUnstick.AppStore", category: "diagnosis")
    private var currentSession: ActivitySession?

    init(store: BoundedSessionStore? = nil,
         probes: any StoreNetworkProbing = StoreNetworkProbe(),
         bonjour: any BonjourBrowsing = SystemBonjourBrowser()) throws {
        if let store { sessionsStore = store }
        else {
            let support = try FileManager.default.url(for: .applicationSupportDirectory,
                in: .userDomainMask, appropriateFor: nil, create: true)
            sessionsStore = try BoundedSessionStore(fileURL: support
                .appendingPathComponent("NetUnstickAppStore", isDirectory: true)
                .appendingPathComponent("sessions.json"))
        }
        self.probes = probes
        self.bonjour = bonjour
    }

    func diagnose() async throws -> [OperationResult] { try await diagnose(onCheck: { _, _, _ in }) }

    func diagnose(onCheck: @escaping @Sendable (OperationResult, Int, Int) -> Void) async throws -> [OperationResult] {
        let session = newSession()
        try await sessionsStore.startSession(session)
        currentSession = session
        var results: [OperationResult] = []
        for check in StoreCheck.allCases {
            try Task.checkCancellation()
            let result = await probes.run(check)
            try Task.checkCancellation()
            try await sessionsStore.append(result, to: session.id)
            results.append(result)
            onCheck(result, results.count, StoreCheck.allCases.count + 1)
            logger.info("Check \(result.operationID, privacy: .public): \(result.outcome.rawValue, privacy: .public)")
        }
        try Task.checkCancellation()
        let started = Date()
        let observation = await bonjour.browse(.airplay, timeout: .seconds(2))
        try Task.checkCancellation()
        let outcome: OperationOutcome
        switch observation.reason {
        case .servicesFound: outcome = .success
        case .permissionDenied: outcome = .permissionDenied
        case .timedOut: outcome = .timedOut
        case .cancelled: outcome = .cancelled
        case .browserFailed: outcome = .failure
        default: outcome = .skipped
        }
        let result = StoreNetworkProbe.result(id: "bonjour_discovery", started: started,
            outcome: outcome, reason: observation.reason.rawValue, count: observation.count)
        try await sessionsStore.append(result, to: session.id)
        results.append(result)
        onCheck(result, results.count, results.count)
        return results
    }

    func repairCandidate() -> RepairCandidatePresentation? { nil }
    func refreshVPN(stabilize: Bool) async -> VPNAssessment {
        // The sandbox cannot establish global VPN state. This is not a claim of disconnection.
        .init(state: .unknown, reasonCode: .incompleteSnapshot)
    }
    func loadSessions() async throws -> [ActivitySession] { try await sessionsStore.sessions() }
    func clearHistory() async throws {
        try await sessionsStore.removeAll()
        currentSession = nil
    }
    func recordCancellation() async {
        guard let session = currentSession else { return }
        let now = Date()
        let result = StoreNetworkProbe.result(id: "diagnosis_cancelled", started: now,
            outcome: .cancelled, reason: "cancelled")
        // The invoking diagnostic task is cancelled, but the explicit cancellation record must persist.
        let store = sessionsStore
        _ = try? await Task.detached { try await store.append(result, to: session.id) }.value
    }
    func testDeviceConnection(host: String, port: UInt16) async -> OperationResult? {
        do {
            let session: ActivitySession
            if let currentSession { session = currentSession }
            else {
                session = newSession()
                try await sessionsStore.startSession(session)
                currentSession = session
            }
            let result = await probes.device(host: host, port: port)
            try await sessionsStore.append(result, to: session.id)
            return result
        } catch {
            logger.error("Could not persist device connection result")
            return nil
        }
    }
    private func newSession() -> ActivitySession {
        let os = ProcessInfo.processInfo.operatingSystemVersion
        return ActivitySession(startedAt: Date(),
            appVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.2.0",
            macOSVersion: "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)")
    }
}
#endif
