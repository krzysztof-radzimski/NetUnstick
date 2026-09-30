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
    private let deviceProbe: any DeviceConnectionProbing
    private let repairChecks: any RepairCheckRunning
    private let repairHelper: (any RepairHelperCalling)?
    private let repairWait: any RepairWaiting
    private let dhcpInterfaces: @Sendable () -> Set<String>
    private var plans: [RepairPlan] = []
    private var selectedPlanIndex = 0
    private var currentSession: ActivitySession?
    private(set) var vpn: VPNAssessment = .init(state: .unknown, reasonCode: .stabilizationPending)
    private(set) var vpnServices: VPNServiceStatus = .unknown
    private(set) var helperHandshake: HelperHandshakePresentation = .notRun

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
         deviceProbe: any DeviceConnectionProbing = SystemDeviceConnectionProbe(),
         fileSharing: any FileSharingProbing = SystemFileSharingProbe(),
         filters: any ContentFilterProbing = SystemContentFilterProbe(),
         repairChecks: any RepairCheckRunning = SystemRepairChecks(),
         repairHelper: (any RepairHelperCalling)? = nil,
         repairWait: any RepairWaiting = BoundedRepairWait(),
         dhcpInterfaces: @escaping @Sendable () -> Set<String> = { SystemDHCPInterfaceSource.detect() },
         renderer: ReportRenderer = ReportRenderer()) throws {
        self.collector = collector
        self.detector = detector
        self.diagnosis = DiagnosisEngine(collector: collector, probe: probe, detector: detector, bonjourBrowser: bonjour,
                                         fileSharing: fileSharing, filters: filters)
        self.sessionsStore = try store ?? BoundedSessionStore()
        self.helperClient = helper
        self.deviceProbe = deviceProbe
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
        vpnServices = report.rawSnapshot.vpnServices
        for error in report.rawSnapshot.errors {
            logger.error("Network collection: \(error.code, privacy: .public)")
        }
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
                     verification: plan.summary.verification,
                     allowsWhenResidualRoute: plan.kind == .removeStaleTunnelRoutes)
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

    /// The host and port are used for the probe only; the persisted result holds codes and the interface type.
    func testDeviceConnection(host: String, port: UInt16) async -> OperationResult? {
        let session: ActivitySession
        if let currentSession { session = currentSession } else {
            let os = ProcessInfo.processInfo.operatingSystemVersion
            session = ActivitySession(startedAt: Date(),
                appVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1.0",
                macOSVersion: "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)")
            do { try await sessionsStore.startSession(session) } catch { logger.error("Could not start device test session"); return nil }
            currentSession = session
        }
        let result = await DeviceConnectionCheck(host: host, port: port, probe: deviceProbe).run(context: .init())
        do { try await sessionsStore.append(result, to: session.id) } catch { logger.error("Could not persist device test result") }
        logger.info("Device connection test: \(result.outcome.rawValue, privacy: .public), code \(result.error?.code ?? "none", privacy: .public)")
        return result
    }

    func refreshVPN(stabilize: Bool = false) async -> VPNAssessment {
        if stabilize {
            vpn = await detector.stabilizeAfterDisconnect(collecting: collector)
        } else {
            let snapshot = await collector.collect()
            vpn = detector.assess(snapshot)
            vpnServices = snapshot.vpnServices
        }
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
    func unregisterHelper() -> HelperPresentationState {
        _ = helperClient.unregisterForUpdate()
        return helper
    }
    /// Runs at launch and on demand. launchd refuses a daemon whose build changed since registration.
    /// The app first registers again in place (keeps the Login Items record), asks again, and only
    /// then replaces the registration after the removal has settled, so an update needs no manual
    /// step as long as the earlier approval is retained. If the system still asks for approval,
    /// Settings shows it.
    func verifyHelper() async -> HelperHandshakePresentation {
        guard helperClient.status == .enabled else { helperHandshake = .notRun; return helperHandshake }
        var reply = await handshake()
        if Self.needsRegistrationRefresh(reply.code) {
            logger.notice("Helper handshake failed: \(reply.code.rawValue, privacy: .public); registering again in place")
            if helperClient.reregisterInPlace() == .enabled { reply = await handshake() }
        }
        if Self.needsRegistrationRefresh(reply.code) {
            logger.notice("Helper still not answering: \(reply.code.rawValue, privacy: .public); replacing the registration")
            let status = await helperClient.refreshRegistrationAfterUpdate()
            guard status == .enabled else {
                helperHandshake = .failed(code: status.rawValue)
                logger.notice("Helper registration refresh ended with \(status.rawValue, privacy: .public)")
                return helperHandshake
            }
            reply = await handshake()
        }
        helperHandshake = reply.code == .success
            ? .responding(version: Int(reply.result.after.values[.count] ?? "") ?? 0)
            : .failed(code: reply.code.rawValue)
        logger.notice("Helper handshake \(reply.code.rawValue, privacy: .public)")
        return helperHandshake
    }
    private static func needsRegistrationRefresh(_ code: PrivilegedCode) -> Bool {
        [.disconnected, .timedOut, .executionFailed].contains(code)
    }
    private func handshake() async -> PrivilegedReply {
        await withCheckedContinuation { continuation in helperClient.handshake { continuation.resume(returning: $0) } }
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
