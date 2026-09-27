import Foundation
import NetUnstickCore

@MainActor enum CompositionRoot {
    static func testOption(_ option: String) -> Bool {
        #if DEBUG
        return ProcessInfo.processInfo.arguments.contains(option)
        #else
        return false
        #endif
    }
    static func makeStore() -> PresentationStore {
        #if DEBUG
        if let scenario = ProcessInfo.processInfo.arguments.first(where: { $0.hasPrefix("--integration-scenario=") })?
            .replacingOccurrences(of: "--integration-scenario=", with: ""),
           let environment = try? IntegrationFixture.make(scenario: scenario) {
            return PresentationStore(service: environment)
        }
        if ProcessInfo.processInfo.arguments.contains(where: { $0.hasPrefix("--scenario=") }) {
            return PresentationStore(service: MockPresentationService.fromLaunchArguments())
        }
        #endif
        do { return PresentationStore(service: try AppEnvironment()) }
        catch { return PresentationStore(service: UnavailableEnvironment()) }
    }
}

@MainActor private struct UnavailableEnvironment: PresentationService {
    let scenario = "unavailable"
    let helper = HelperPresentationState.unavailable
    func diagnose() async throws -> [OperationResult] { throw SessionStoreError.ioFailure }
    func repairCandidate() -> RepairCandidatePresentation? { nil }
}
