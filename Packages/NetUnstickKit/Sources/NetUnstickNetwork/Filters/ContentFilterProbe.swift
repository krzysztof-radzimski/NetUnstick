import Foundation
import NetUnstickCore

/// Closed outcome codes for the read-only look at socket content filters on this Mac.
/// Since macOS 15 the built-in firewall is itself a Network Extension content filter attached
/// to sockets; such a filter can end sessions of kernel clients (SMB, AFP) toward other Macs
/// even though the TCP port answers, which shows up as "Socket is not connected".
public enum ContentFilterReason: String, Sendable, CaseIterable {
    case noFilter, firewallFilterActive, thirdPartyFilterActive, filterActive, dataIncomplete, cancelled

    public var message: String {
        switch self {
        case .noFilter:
            return "Na tym komputerze nie działa żaden filtr treści na gniazdach; połączenia wychodzące nie są przechwytywane."
        case .firewallFilterActive:
            return "Zapora tego komputera działa jako filtr treści na gniazdach (tak działa zapora macOS od wersji 15). Jeśli sesje SMB lub AFP do innych komputerów urywają się mimo działającego portu, wykonaj test urządzenia na porcie 445 albo spróbuj z wyłączoną zaporą."
        case .thirdPartyFilterActive:
            return "Na tym komputerze działa filtr treści na gniazdach innego programu (VPN lub ochrona), choć zapora systemowa jest wyłączona; może on przerywać sesje SMB do innych komputerów."
        case .filterActive:
            return "Na tym komputerze działa filtr treści na gniazdach; nie udało się ustalić, czy to zapora systemowa."
        case .dataIncomplete:
            return "Nie udało się odczytać stanu filtrów treści."
        case .cancelled:
            return "Sprawdzenie zostało anulowane."
        }
    }
}

/// Ephemeral observation: counts and flags only, never process or product names.
public struct ContentFilterObservation: Sendable, Equatable {
    public let activeFilters: Int?
    public let attachedSockets: Int?
    public let firewallEnabled: Bool?
    public let blockAllIncoming: Bool?
    public init(activeFilters: Int?, attachedSockets: Int?, firewallEnabled: Bool?, blockAllIncoming: Bool?) {
        self.activeFilters = activeFilters
        self.attachedSockets = attachedSockets
        self.firewallEnabled = firewallEnabled
        self.blockAllIncoming = blockAllIncoming
    }
    public var filterActive: Bool? { activeFilters.map { $0 > 0 } }
}

public protocol ContentFilterProbing: Sendable {
    func observe() async -> ContentFilterObservation
}

/// Reads two kernel counters and two firewall flags with fixed commands; no privileges needed.
public struct SystemContentFilterProbe: ContentFilterProbing {
    public static let sysctlExecutable = "/usr/sbin/sysctl"
    public static let firewallExecutable = "/usr/libexec/ApplicationFirewall/socketfilterfw"
    public init() {}

    public func observe() async -> ContentFilterObservation {
        let active = await Self.counter("net.cfil.active_count")
        let attached = await Self.counter("net.cfil.sock_attached_count")
        let enabled = await Self.firewallFlag("--getglobalstate")
        let blockAll = await Self.firewallFlag("--getblockall")
        return .init(activeFilters: active, attachedSockets: attached, firewallEnabled: enabled, blockAllIncoming: blockAll)
    }

    private static func counter(_ name: String) async -> Int? {
        guard let output = try? await BoundedProcess.run(executable: sysctlExecutable, arguments: ["-n", name],
                                                          timeout: 3, outputLimit: 4096) else { return nil }
        return parseCount(output.stdout)
    }

    private static func firewallFlag(_ option: String) async -> Bool? {
        guard let output = try? await BoundedProcess.run(executable: firewallExecutable, arguments: [option],
                                                          timeout: 3, outputLimit: 4096) else { return nil }
        return parseFirewallState(output.stdout)
    }

    public static func parseCount(_ text: String) -> Int? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let value = Int(trimmed), value >= 0 else { return nil }
        return value
    }

    /// "Firewall is enabled. (State = 1)" / "Firewall has block all state set to disabled."
    public static func parseFirewallState(_ text: String) -> Bool? {
        let lower = text.lowercased()
        if lower.contains("disabled") { return false }
        if lower.contains("enabled") { return true }
        return nil
    }
}

/// Informational check: a filter is a legitimate setting, so the outcome is never a failure.
/// The device test on port 445 turns it into a verdict when an SMB session cannot start.
public struct ContentFilterCheck: DiagnosticCheck {
    public static let checkID = "content_filter"
    public let id = ContentFilterCheck.checkID
    public let name = ContentFilterCheck.checkID
    private let probe: any ContentFilterProbing

    public init(probe: any ContentFilterProbing = SystemContentFilterProbe()) { self.probe = probe }

    public func run(context: OperationContext) async -> OperationResult {
        let start = context.clock.now()
        let reason: ContentFilterReason
        var observation: ContentFilterObservation?
        if Task.isCancelled || (try? context.cancellation.checkCancellation()) == nil {
            reason = .cancelled
        } else {
            let observed = await probe.observe()
            observation = observed
            reason = Self.decide(observed)
        }
        let outcome: OperationOutcome
        switch reason {
        case .noFilter, .firewallFilterActive, .thirdPartyFilterActive, .filterActive: outcome = .success
        case .dataIncomplete: outcome = .skipped
        case .cancelled: outcome = .cancelled
        }
        var values: [EvidenceKey: EvidenceValue] = [
            .checkStatus: .status(outcome == .success ? .passed : .unknown),
            .errorCode: .errorCode(reason.rawValue)
        ]
        if let count = observation?.activeFilters { values[.count] = .count(count) }
        if let firewall = observation?.firewallEnabled { values[.firewallStatus] = .status(firewall ? .active : .inactive) }
        if let filter = observation?.filterActive { values[.contentFilterStatus] = .status(filter ? .active : .inactive) }
        let next: NextStep = reason == .dataIncomplete || reason == .cancelled ? .retryCheck : .reviewDetails
        return try! OperationResult(operationID: id, name: name, kind: .diagnostic, startedAt: start,
            endedAt: max(start, context.clock.now()), outcome: outcome, after: EvidenceSanitizer.sanitize(values),
            nextStep: next.rawValue)
    }

    public static func decide(_ observation: ContentFilterObservation) -> ContentFilterReason {
        guard let active = observation.activeFilters else { return .dataIncomplete }
        if active == 0 { return .noFilter }
        switch observation.firewallEnabled {
        case .some(true): return .firewallFilterActive
        case .some(false): return .thirdPartyFilterActive
        case .none: return .filterActive
        }
    }
}
