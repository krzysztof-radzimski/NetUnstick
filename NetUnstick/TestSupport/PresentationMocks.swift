import Foundation
import SwiftUI
import NetUnstickCore

@MainActor struct MockPresentationService: PresentationService {
    let scenario: String
    var helper: HelperPresentationState {
        switch scenario {
        case "permission-denied": .denied
        case "helper-approval": .approvalRequired
        case "healthy": .available
        default: .unavailable
        }
    }
    static func fromLaunchArguments() -> Self {
        let value = ProcessInfo.processInfo.arguments.first { $0.hasPrefix("--scenario=") }?.replacingOccurrences(of: "--scenario=", with: "") ?? "default"
        return Self(scenario: value)
    }
    func repairCandidate() -> RepairCandidatePresentation? {
        guard ["dns-residue", "route-blocked", "repair-success", "repair-failure"].contains(scenario) else { return nil }
        return RepairCandidatePresentation(change: String(localized: "candidate_change"), reason: String(localized: "candidate_reason"), resource: String(localized: "candidate_resource"), impact: String(localized: "candidate_impact"), permission: String(localized: "candidate_permission"), verification: String(localized: "candidate_verification"))
    }
    func diagnose() async throws -> [OperationResult] {
        try await Task.sleep(for: scenario == "operation-progress" ? .seconds(8) : .milliseconds(450))
        try Task.checkCancellation()
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let names = ["network", "dns", "route", "bonjour"]
        return names.map { name in
            let bad = (scenario == "dns-residue" && name == "dns") || (scenario == "route-blocked" && name == "route") || (scenario == "bonjour-denied" && name == "bonjour") || (scenario == "permission-denied" && name == "bonjour") || (scenario == "timeout" && name == "network") || (scenario == "no-receiver" && name == "bonjour")
            let outcome: OperationOutcome = bad ? (scenario == "no-receiver" ? .skipped : scenario == "permission-denied" || scenario == "bonjour-denied" ? .permissionDenied : scenario == "timeout" ? .timedOut : .failure) : .success
            return try! OperationResult(operationID: "mock.\(name)", name: name, kind: .diagnostic, startedAt: now, endedAt: now.addingTimeInterval(0.2), outcome: outcome, error: bad ? try! OperationError(domain: "Mock", code: scenario.replacingOccurrences(of: "-", with: "_")) : nil, nextStep: bad ? "Run a new diagnosis or contact your administrator." : nil)
        }
    }
}

