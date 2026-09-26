import Foundation
import Darwin
import SystemConfiguration
import NetUnstickCore
import NetUnstickNetwork

public protocol PrivilegedCommandRunning: Sendable {
    func run(executable: String, arguments: [String]) async throws
}

public enum PrivilegedExecutionError: Error, Equatable {
    case permissionDenied, timedOut, nonZeroExit, outputLimit, launchFailed
}

/// The only command implementation. Callers receive no output bytes.
public struct BoundedPrivilegedCommandRunner: PrivilegedCommandRunning {
    public init() {}
    public func run(executable: String, arguments: [String]) async throws {
        guard (executable == "/usr/bin/dscacheutil" && arguments == ["-flushcache"]) ||
              (executable == "/usr/bin/killall" && arguments == ["-HUP", "mDNSResponder"]) ||
              (executable == "/sbin/route" && arguments.count == 7 && arguments[0...2] == ["-n", "delete", "-net"] && arguments[3] == "-ifscope")
        else { throw PrivilegedExecutionError.launchFailed }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LANG": "C"]
        let stdout = Pipe(), stderr = Pipe()
        process.standardOutput = stdout; process.standardError = stderr
        let state = CommandState(process: process)
        stdout.fileHandleForReading.readabilityHandler = { handle in state.consume(handle.availableData) }
        stderr.fileHandleForReading.readabilityHandler = { handle in state.consume(handle.availableData) }
        defer { stdout.fileHandleForReading.readabilityHandler = nil; stderr.fileHandleForReading.readabilityHandler = nil }
        do { try process.run() } catch { throw PrivilegedExecutionError.launchFailed }
        let deadline = DispatchWorkItem { state.expire() }
        DispatchQueue.global().asyncAfter(deadline: .now() + 5, execute: deadline)
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.global().async { process.waitUntilExit(); continuation.resume() }
        }
        deadline.cancel()
        if state.exceeded { throw PrivilegedExecutionError.outputLimit }
        if state.expired { throw PrivilegedExecutionError.timedOut }
        if process.terminationStatus != 0 {
            if process.terminationStatus == 77 { throw PrivilegedExecutionError.permissionDenied }
            throw PrivilegedExecutionError.nonZeroExit
        }
    }
}

private final class CommandState: @unchecked Sendable {
    private let lock = NSLock()
    private let process: Process
    private var bytes = 0
    private var didExpire = false, didExceed = false
    init(process: Process) { self.process = process }
    var expired: Bool { lock.lock(); defer { lock.unlock() }; return didExpire }
    var exceeded: Bool { lock.lock(); defer { lock.unlock() }; return didExceed }
    func consume(_ data: Data) {
        lock.lock(); bytes += data.count
        if bytes > 4096 { didExceed = true }
        let terminate = didExceed && process.isRunning
        lock.unlock()
        if terminate { process.terminate(); forceKillIfNeeded() }
    }
    func expire() {
        lock.lock(); didExpire = true
        let terminate = process.isRunning
        lock.unlock()
        if terminate { process.terminate(); forceKillIfNeeded() }
    }
    private func forceKillIfNeeded() {
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.25) { [process] in
            if process.isRunning { _ = Darwin.kill(process.processIdentifier, SIGKILL) }
        }
    }
}

public protocol DHCPConfigurationChecking: Sendable {
    func configuredInterfaces() -> Set<String>
    func refresh(_ name: String) -> Bool
}

public struct SystemDHCPConfiguration: DHCPConfigurationChecking {
    public init() {}
    public func configuredInterfaces() -> Set<String> {
        guard let store = SCDynamicStoreCreate(nil, "NetUnstick.Helper" as CFString, nil, nil),
              let keys = SCDynamicStoreCopyKeyList(store, "Setup:/Network/Service/.*/IPv4" as CFString) as? [String] else { return [] }
        var result = Set<String>()
        for key in keys {
            guard let ipv4 = SCDynamicStoreCopyValue(store, key as CFString) as? [String: Any],
                  ipv4["ConfigMethod"] as? String == "DHCP" else { continue }
            let interfaceKey = String(key.dropLast("IPv4".count)) + "Interface"
            if let info = SCDynamicStoreCopyValue(store, interfaceKey as CFString) as? [String: Any],
               let name = info["DeviceName"] as? String { result.insert(name) }
        }
        return result
    }
    public func refresh(_ name: String) -> Bool {
        guard let interfaces = SCNetworkInterfaceCopyAll() as? [SCNetworkInterface],
              let item = interfaces.first(where: { SCNetworkInterfaceGetBSDName($0) as String? == name }) else { return false }
        return SCNetworkInterfaceForceConfigurationRefresh(item)
    }
}

public struct PrivilegedRepairExecutor: Sendable {
    private let collector: any NetworkStateCollecting
    private let dhcp: any DHCPConfigurationChecking
    private let runner: any PrivilegedCommandRunning
    public init(collector: any NetworkStateCollecting = SystemNetworkStateCollector(),
                dhcp: any DHCPConfigurationChecking = SystemDHCPConfiguration(),
                runner: any PrivilegedCommandRunning = BoundedPrivilegedCommandRunner()) {
        self.collector = collector; self.dhcp = dhcp; self.runner = runner
    }
    public static func rejectMalformedRequest() -> PrivilegedReply {
        let now = Date()
        let result = try! OperationResult(operationID: UUID().uuidString, name: "privileged_repair", kind: .repair,
            startedAt: now, endedAt: now, outcome: .failure,
            error: try! OperationError(domain: "helper", code: PrivilegedCode.invalidRequest.rawValue),
            nextStep: "Zaktualizuj aplikację i spróbuj ponownie.")
        return PrivilegedReply(code: .invalidRequest, result: result)
    }
    public func perform(_ request: PrivilegedRequest) async -> PrivilegedReply {
        let started = Date()
        var code: PrivilegedCode = .success
        var before: SafeEvidence = .empty
        var after: SafeEvidence = .empty
        do {
            let snapshot = await collector.collect()
            before = SanitizedNetworkSnapshot(raw: snapshot).evidence
            let action = try RepairPolicy.authorize(request, snapshot: snapshot, dhcpInterfaces: dhcp.configuredInterfaces())
            switch action {
            case .refreshResolverCache:
                try await runner.run(executable: "/usr/bin/dscacheutil", arguments: ["-flushcache"])
                try await runner.run(executable: "/usr/bin/killall", arguments: ["-HUP", "mDNSResponder"])
            case .renewDHCP(let name):
                guard dhcp.refresh(name) else { throw PrivilegedExecutionError.nonZeroExit }
            case .removeRoute(let destination, let prefix, let name, let gateway):
                // A second observation minimizes the gap before the exact route deletion.
                let current = await collector.collect()
                guard try RepairPolicy.authorize(request, snapshot: current,
                                                 dhcpInterfaces: dhcp.configuredInterfaces()) == action
                else { throw RepairPolicyError.ambiguousResource }
                try await runner.run(executable: "/sbin/route", arguments: ["-n", "delete", "-net", "-ifscope", name, "\(destination)/\(prefix)", gateway])
            }
            let observed = await collector.collect()
            after = SanitizedNetworkSnapshot(raw: observed).evidence
            if case .removeRoute(let destination, let prefix, _, _) = action {
                guard observed.errors.isEmpty, observed.routes.filter({ $0.destination == "\(destination)/\(prefix)" }).isEmpty else {
                    throw PrivilegedExecutionError.nonZeroExit
                }
            }
        } catch let error as RepairPolicyError {
            switch error {
            case .incompatibleVersion: code = .incompatibleVersion
            case .invalidRequest: code = .invalidRequest
            case .vpnActive: code = .vpnActive
            case .vpnUnknown: code = .vpnUnknown
            case .ambiguousResource: code = .ambiguousResource
            }
        } catch let error as PrivilegedExecutionError {
            switch error {
            case .permissionDenied: code = .permissionDenied
            case .timedOut: code = .timedOut
            case .nonZeroExit: code = .nonZeroExit
            case .outputLimit: code = .outputLimit
            case .launchFailed: code = .executionFailed
            }
        } catch { code = .executionFailed }
        let outcome: OperationOutcome = code == .success ? .success :
            code == .timedOut ? .timedOut : code == .permissionDenied ? .permissionDenied :
            [.vpnActive, .vpnUnknown, .ambiguousResource].contains(code) ? .skipped : .failure
        let next = code == .success ? "Uruchom ponownie powiązane sprawdzenie przed uznaniem naprawy." :
            "Sprawdź stan VPN i konfigurację sieci; jeśli problem trwa, skontaktuj się z administratorem."
        let result = try! OperationResult(operationID: UUID().uuidString, name: "privileged_repair", kind: .repair,
                                          startedAt: started, endedAt: Date(), outcome: outcome, before: before, after: after,
                                          error: code == .success || outcome == .skipped ? nil : try! OperationError(domain: "helper", code: code.rawValue),
                                          nextStep: next)
        return PrivilegedReply(code: code, result: result)
    }
}
