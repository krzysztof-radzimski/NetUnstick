import Foundation
import os
import NetUnstickCore
import NetUnstickNetwork
import NetUnstickRepair

/// The production boundary owns raw observations only while building a plan.
@MainActor final class AppEnvironment: PresentationService {
    let scenario = "production"
    private let collector: any NetworkStateCollecting
    private let detector: VPNStateDetector
    private let diagnosis: DiagnosisEngine
    private let sessionsStore: BoundedSessionStore
    private let helperClient: PrivilegedHelperClient
    private let renderer: ReportRenderer
    private let logger = Logger(subsystem: "org.netunstick.NetUnstick", category: "diagnosis")
    private let repairChecks: any RepairCheckRunning
    private let repairHelper: (any RepairHelperCalling)?
    private let repairWait: any RepairWaiting
    private let dhcpInterfaces: @Sendable () -> Set<String>
    private var plans: [RepairPlan] = []
    private var selectedPlanIndex = 0
    private var currentSession: ActivitySession?
    private(set) var vpn: VPNAssessment = .init(state: .unknown, reasonCode: .stabilizationPending)

    var helper: HelperPresentationState {
        switch helperClient.status {
        case .enabled: .available
        case .requiresApproval: .approvalRequired
        case .notRegistered: .unavailable
        case .notFound: .denied
        }
    }

    init(collector: any NetworkStateCollecting = SystemNetworkStateCollector(),
         detector: VPNStateDetector = VPNStateDetector(),
         probe: any NetworkConnectivityProbing = SystemNetworkConnectivityProbe(),
         bonjour: any BonjourBrowsing = SystemBonjourBrowser(),
         store: BoundedSessionStore? = nil,
         helper: PrivilegedHelperClient = PrivilegedHelperClient(),
         repairChecks: any RepairCheckRunning = SystemRepairChecks(),
         repairHelper: (any RepairHelperCalling)? = nil,
         repairWait: any RepairWaiting = BoundedRepairWait(),
         dhcpInterfaces: @escaping @Sendable () -> Set<String> = { SystemDHCPInterfaceSource.detect() },
         renderer: ReportRenderer = ReportRenderer()) throws {
        self.collector = collector
        self.detector = detector
        self.diagnosis = DiagnosisEngine(collector: collector, probe: probe, detector: detector, bonjourBrowser: bonjour)
        self.sessionsStore = try store ?? BoundedSessionStore()
        self.helperClient = helper
        self.repairChecks = repairChecks
        self.repairHelper = repairHelper
        self.repairWait = repairWait
        self.dhcpInterfaces = dhcpInterfaces
        self.renderer = renderer
    }

    func diagnose() async throws -> [OperationResult] { try await diagnose(onCheck: { _, _, _ in }) }

    func diagnose(onCheck: @escaping @Sendable (OperationResult, Int, Int) -> Void) async throws -> [OperationResult] {
        plans = []
        let os = ProcessInfo.processInfo.operatingSystemVersion
        let session = ActivitySession(startedAt: Date(),
            appVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1.0",
            macOSVersion: "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)")
        do { try await sessionsStore.startSession(session) }
        catch { logger.error("Could not start diagnosis session"); throw error }
        currentSession = session
        let report = await diagnosis.diagnose(onCheck: onCheck)
        vpn = report.vpn
        // Persist each structured result. A failed write is surfaced and no repair is offered.
        for result in report.results {
            do { try await sessionsStore.append(result, to: session.id) }
            catch { logger.error("Could not persist diagnostic result"); throw error }
            logger.info("Check \(result.operationID, privacy: .public): \(result.outcome.rawValue, privacy: .public), code \(result.error?.code ?? "none", privacy: .public)")
        }
        if !Task.isCancelled {
            let plans = RepairPlanBuilder().build(report: report, snapshot: report.rawSnapshot, dhcpInterfaces: dhcpInterfaces())
            self.plans = plans.plans.filter { plan in
                // An absent receiver alone is an environment observation, not a repairable fault.
                plan.reasonCode != BonjourReason.noServices.rawValue || report.state == .fault
            }
            selectedPlanIndex = 0
        }
        return report.results
    }

    func repairCandidate() -> RepairCandidatePresentation? {
        guard plans.indices.contains(selectedPlanIndex) else { return nil }
        return present(plans[selectedPlanIndex])
    }
    func repairCandidates() -> [RepairCandidatePresentation] { plans.map(present) }
    func selectRepairCandidate(_ index: Int) { if plans.indices.contains(index) { selectedPlanIndex = index } }
    private func present(_ plan: RepairPlan) -> RepairCandidatePresentation {
        return .init(change: plan.summary.change,
                     reason: "\(plan.summary.purpose) (\(plan.reasonCode))",
                     resource: plan.summary.resource, impact: plan.summary.possibleImpact,
                     permission: plan.summary.requiresAdministrator ? "Wymaga zatwierdzonego helpera" : "Bez uprawnień administratora",
                     verification: plan.summary.verification)
    }

    func executeRepair(onPhase: @escaping @Sendable (String, OperationOutcome) -> Void) async -> OperationResult? {
        guard plans.indices.contains(selectedPlanIndex), let session = currentSession else { return nil }
        let plan = plans[selectedPlanIndex]
        // The executor collects and validates VPN and the target again immediately before action.
        let executor = RepairExecutor(collector: collector, checks: repairChecks,
            helper: repairHelper ?? AppRepairHelper(client: helperClient), wait: repairWait,
            dhcpInterfaces: dhcpInterfaces, store: sessionsStore, session: session)
        let result = await executor.execute(plan, onPhase: onPhase)
        plans = []
        return result
    }

    func refreshVPN(stabilize: Bool = false) async -> VPNAssessment {
        vpn = stabilize ? await detector.stabilizeAfterDisconnect(collecting: collector) : detector.assess(await collector.collect())
        return vpn
    }

    func loadSessions() async throws -> [ActivitySession] { try await sessionsStore.sessions() }
    func recordCancellation() async {
        let session: ActivitySession
        if let currentSession { session = currentSession }
        else {
            let os = ProcessInfo.processInfo.operatingSystemVersion
            session = ActivitySession(startedAt: Date(), appVersion: "0.1.0",
                macOSVersion: "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)")
            currentSession = session
            let store = sessionsStore
            _ = try? await Task.detached { try await store.startSession(session) }.value
        }
        let now = Date()
        guard let result = try? OperationResult(operationID: UUID().uuidString, name: "diagnosis_cancelled",
            kind: .diagnostic, startedAt: now, endedAt: now, outcome: .cancelled) else { return }
        let store = sessionsStore
        _ = try? await Task.detached { try await store.append(result, to: session.id) }.value
    }
    func preview(_ session: ActivitySession) -> String { renderer.preview(session: session).body }
    func registerHelper() -> HelperPresentationState {
        _ = helperClient.registerForSelectedRepair()
        return helper
    }
    func openHelperSettings() { helperClient.openLoginItems() }
}

private struct AppRepairHelper: RepairHelperCalling, @unchecked Sendable {
    let client: PrivilegedHelperClient
    func perform(_ action: PrivilegedAction) async -> PrivilegedReply {
        await withCheckedContinuation { continuation in
            client.perform(action) { continuation.resume(returning: $0) }
        }
    }
}
