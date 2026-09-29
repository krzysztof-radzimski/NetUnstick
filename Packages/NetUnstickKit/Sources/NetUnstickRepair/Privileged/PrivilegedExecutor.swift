import Foundation
import Darwin
import os
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
        guard executable == "/sbin/route" && arguments.starts(with: ["-n", "delete", "-net"]) &&
              ((arguments.count == 7 && arguments[3] == "-ifscope") || arguments.count == 5)
        else { throw PrivilegedExecutionError.launchFailed }
        do {
            // Exit is observed through the shared kqueue-based launcher; five seconds and 4 KiB of output at most.
            _ = try await BoundedProcess.run(executable: executable, arguments: arguments,
                                             environment: ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LANG": "C"],
                                             timeout: 5, outputLimit: 4096)
        } catch let error as ProcessRunError {
            switch error {
            case .timedOut, .cancelled: throw PrivilegedExecutionError.timedOut
            case .outputTooLarge: throw PrivilegedExecutionError.outputLimit
            case .nonZeroExit(let status): throw status == 77 ? PrivilegedExecutionError.permissionDenied : .nonZeroExit
            case .permissionDenied: throw PrivilegedExecutionError.permissionDenied
            case .launchFailed, .invalidEncoding: throw PrivilegedExecutionError.launchFailed
            }
        } catch {
            throw PrivilegedExecutionError.launchFailed
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
    private let collectionTimeout: Duration
    private let logger = Logger(subsystem: "org.netunstick.NetUnstick", category: "helper")
    /// Every observation inside the helper is raced against `collectionTimeout`, so a system
    /// API that blocks in the daemon context produces a `timedOut` reply instead of a hang.
    public init(collector: any NetworkStateCollecting = SystemNetworkStateCollector(),
                dhcp: any DHCPConfigurationChecking = SystemDHCPConfiguration(),
                runner: any PrivilegedCommandRunning = BoundedPrivilegedCommandRunner(),
                collectionTimeout: Duration = .seconds(12)) {
        self.collector = collector; self.dhcp = dhcp; self.runner = runner
        self.collectionTimeout = collectionTimeout
    }

    private func collectBounded(_ phase: String) async throws -> RawNetworkSnapshot {
        logger.info("helper observe \(phase, privacy: .public)")
        let (stream, output) = AsyncStream.makeStream(of: RawNetworkSnapshot?.self, bufferingPolicy: .bufferingNewest(1))
        let worker = Task { output.yield(await collector.collect()); output.finish() }
        let timer = Task { try? await Task.sleep(for: collectionTimeout); output.yield(nil); output.finish() }
        var iterator = stream.makeAsyncIterator()
        let result = await iterator.next() ?? nil
        worker.cancel(); timer.cancel(); output.finish()
        guard let result else {
            logger.error("helper observe \(phase, privacy: .public) timed out")
            throw PrivilegedExecutionError.timedOut
        }
        return result
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
            let snapshot = try await collectBounded("before")
            before = SanitizedNetworkSnapshot(raw: snapshot).evidence
            let action = try RepairPolicy.authorize(request, snapshot: snapshot, dhcpInterfaces: dhcp.configuredInterfaces())
            logger.info("helper authorized")
            switch action {
            case .renewDHCP(let name):
                guard dhcp.refresh(name) else { throw PrivilegedExecutionError.nonZeroExit }
            case .removeRoute(let destination, let prefix, let name, let gateway):
                // A second observation minimizes the gap before the exact route deletion.
                let current = try await collectBounded("recheck")
                guard try RepairPolicy.authorize(request, snapshot: current,
                                                 dhcpInterfaces: dhcp.configuredInterfaces()) == action
                else { throw RepairPolicyError.ambiguousResource }
                // route(8): -ifscope is required only for entries with RTF_IFSCOPE.
                // The residual tunnel route on this host is unscoped, so a scoped
                // delete would target a different routing-table entry.
                let target = "\(destination)/\(prefix)"
                let arguments = name.hasPrefix("utun")
                    ? ["-n", "delete", "-net", target, gateway]
                    : ["-n", "delete", "-net", "-ifscope", name, target, gateway]
                try await runner.run(executable: "/sbin/route", arguments: arguments)
            case .removeRoutes(let routes):
                // The observed set must still equal the request immediately before the first deletion.
                let current = try await collectBounded("recheck")
                guard try RepairPolicy.authorize(request, snapshot: current,
                                                 dhcpInterfaces: dhcp.configuredInterfaces()) == action
                else { throw RepairPolicyError.ambiguousResource }
                // Policy admits only unscoped entries, so network plus next hop names each one exactly.
                // One bounded command per entry; the first failure stops the sequence.
                for (index, route) in routes.enumerated() {
                    logger.info("helper command \(index + 1, privacy: .public) of \(routes.count, privacy: .public)")
                    try await runner.run(executable: "/sbin/route",
                                         arguments: ["-n", "delete", "-net", route.cidr, route.gateway])
                }
            }
            let observed = try await collectBounded("after")
            after = SanitizedNetworkSnapshot(raw: observed).evidence
            if case .removeRoute(let destination, let prefix, _, _) = action {
                guard observed.errors.isEmpty, observed.routes.filter({ $0.destination == "\(destination)/\(prefix)" }).isEmpty else {
                    throw PrivilegedExecutionError.nonZeroExit
                }
            }
            if case .removeRoutes(let routes) = action {
                guard observed.errors.isEmpty,
                      !observed.routes.contains(where: { row in routes.contains { $0.matches(row) } }) else {
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
        logger.info("helper reply \(code.rawValue, privacy: .public)")
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
