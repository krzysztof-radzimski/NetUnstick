import XCTest
import NetUnstickNetwork

/// Opt-in host integration: NETUNSTICK_READ_ONLY_SMOKE=1 swift test --filter HostDiagnosisSmokeTests
final class HostDiagnosisSmokeTests: XCTestCase {
    func testCurrentHostDiagnosisIsReadOnlyAndConservative() async throws {
        guard ProcessInfo.processInfo.environment["NETUNSTICK_READ_ONLY_SMOKE"] == "1" else {
            throw XCTSkip("Opt-in read-only host smoke test")
        }
        let report = await DiagnosisEngine().diagnose()
        // Eight network checks plus local multicast, Bonjour discovery and permission, then file sharing readiness.
        XCTAssertEqual(report.results.count, DiagnosisEngine.checkCount)
        XCTAssertTrue(report.results.allSatisfy { $0.kind == .diagnostic && $0.endedAt >= $0.startedAt })
        if report.vpn.state != .inactive {
            XCTAssertTrue(report.candidates.allSatisfy(\.unsafeWhileVPNPresent))
        }
        if let internet = report.results.first(where: { $0.operationID == NetworkCheckKind.internetPath.id }),
           internet.after.values[.errorCode] == NetworkCheckReason.internetUnavailable.rawValue {
            XCTAssertEqual(internet.outcome, .skipped)
        }
        // Only closed reason codes and outcomes are printed; no address, name or interface leaves the test.
        let lines = report.results.map { "\($0.operationID)=\($0.outcome.rawValue)/\($0.after.values[.errorCode] ?? "-")" }
        print("NETUNSTICK_HOST_SMOKE: state=\(report.state.rawValue) vpn=\(report.vpn.state.rawValue)/\(report.vpn.reasonCode.rawValue) " +
              "vpnServices=\(report.rawSnapshot.vpnServices.rawValue) vpnTunnels=\(TunnelSignals.vpnTunnelNames(in: report.rawSnapshot).count) " +
              "checks: " + lines.joined(separator: " "))
        // Per-tunnel classification counters help explain a non-inactive verdict without naming anything.
        let raw = report.rawSnapshot
        let tunnels = raw.interfaces.filter { TunnelSignals.isTunnelName($0.name) }
        for tunnel in tunnels {
            let linkLocalOnly = !tunnel.addresses.isEmpty && tunnel.addresses.allSatisfy { IPPrefix(address: $0)?.isLinkLocal == true }
            let forwarding = raw.routes.filter { $0.interfaceName == tunnel.name && TunnelSignals.isForwardingRoute($0) }.count
            let anyRoutes = raw.routes.filter { $0.interfaceName == tunnel.name }.count
            let resolvers = raw.resolvers.filter { $0.interfaceName == tunnel.name }.count
            let store = raw.dynamicStoreTunnelInterfaces.contains(tunnel.name)
            let selected = raw.path?.selectedInterfaces.contains(tunnel.name) ?? false
            print("NETUNSTICK_HOST_TUNNEL: up=\(tunnel.isUp) addresses=\(tunnel.addresses.count) linkLocalOnly=\(linkLocalOnly) " +
                  "routes=\(anyRoutes) forwarding=\(forwarding) resolvers=\(resolvers) store=\(store) selected=\(selected) " +
                  "system=\(TunnelSignals.isSystemInternalTunnel(tunnel, in: raw))")
        }
    }
}
