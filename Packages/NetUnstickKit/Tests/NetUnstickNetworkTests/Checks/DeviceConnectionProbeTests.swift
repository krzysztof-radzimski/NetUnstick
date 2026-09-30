import Foundation
import Network
import XCTest
import NetUnstickCore
@testable import NetUnstickNetwork

final class DeviceConnectionProbeTests: XCTestCase {
    private func listen() throws -> (NWListener, UInt16) {
        let listener = try NWListener(using: .tcp, on: .any)
        listener.newConnectionHandler = { connection in connection.cancel() }
        let ready = expectation(description: "listener ready")
        listener.stateUpdateHandler = { state in if case .ready = state { ready.fulfill() } }
        listener.start(queue: DispatchQueue(label: "NetUnstick.DeviceProbeTests"))
        wait(for: [ready], timeout: 5)
        return (listener, listener.port?.rawValue ?? 0)
    }

    func testLocalListenerIsReachableAndClosedPortIsRefused() async throws {
        let (listener, port) = try listen()
        defer { listener.cancel() }
        let probe = SystemDeviceConnectionProbe()
        let reachable = await probe.probe(host: "127.0.0.1", port: port, timeout: .seconds(3))
        XCTAssertEqual(reachable.reason, .reachable)
        XCTAssertEqual(reachable.interfaceType, .loopback)
        XCTAssertFalse(reachable.viaTunnel)
        listener.cancel()
        try await Task.sleep(for: .milliseconds(200))
        let refused = await probe.probe(host: "127.0.0.1", port: port, timeout: .seconds(3))
        XCTAssertEqual(refused.reason, .refused)
    }

    func testNameRouteAndInputFailuresAreDistinct() async {
        let probe = SystemDeviceConnectionProbe()
        let unresolved = await probe.probe(host: "no-such-host.invalid", port: 445, timeout: .seconds(4))
        XCTAssertEqual(unresolved.reason, .nameUnresolved)
        // TEST-NET-1 is never routed on the public Internet; a private host route may also refuse it outright.
        let silent = await probe.probe(host: "192.0.2.1", port: 445, timeout: .seconds(1))
        XCTAssertTrue([.timedOut, .unreachable].contains(silent.reason), silent.reason.rawValue)
        for host in ["", "mac studio", "host;id", "$(whoami)", String(repeating: "a", count: 300)] {
            let invalid = await probe.probe(host: host, port: 445, timeout: .seconds(1))
            XCTAssertEqual(invalid.reason, .invalidInput, host)
        }
        XCTAssertNil(DeviceConnectionInput.port(from: "0"))
        XCTAssertNil(DeviceConnectionInput.port(from: "70000"))
        XCTAssertEqual(DeviceConnectionInput.port(from: " 445 "), 445)
        XCTAssertTrue(DeviceConnectionInput.isValidHost("Mac-Studio.local"))
        XCTAssertTrue(DeviceConnectionInput.isValidHost("fe80::1%en0"))
    }

    /// Opt-in field check: NETUNSTICK_DEVICE_LIVE="host:port" prints only the outcome codes.
    func testLiveDeviceWhenExplicitlyRequested() async throws {
        guard let target = ProcessInfo.processInfo.environment["NETUNSTICK_DEVICE_LIVE"] else {
            throw XCTSkip("Set NETUNSTICK_DEVICE_LIVE=host:port to probe a real device")
        }
        let parts = target.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 2, let port = DeviceConnectionInput.port(from: parts[1]) else { return XCTFail("Use host:port") }
        let result = await DeviceConnectionCheck(host: parts[0], port: port).run(context: .init())
        print("NETUNSTICK_DEVICE_LIVE: outcome=\(result.outcome.rawValue) code=\(result.after.values[.errorCode] ?? "-") " +
              "interface=\(result.after.values[.interfaceType] ?? "-") viaTunnel=\(result.after.values[.networkStatus] == "active") " +
              "ipv4=\(result.after.values[.ipv4Result] ?? "-") ipv6=\(result.after.values[.ipv6Result] ?? "-") smb=\(result.after.values[.smbResult] ?? "-") " +
              "firewall=\(result.after.values[.firewallStatus] ?? "-") filter=\(result.after.values[.contentFilterStatus] ?? "-") next=\(result.nextStep ?? "-")")
    }

    func testCheckResultCarriesOnlyCodesNeverTheHost() async throws {
        struct Fixed: DeviceConnectionProbing {
            let observation: DeviceConnectionObservation
            func probe(host: String, port: UInt16, timeout: Duration) async -> DeviceConnectionObservation { observation }
        }
        let host = "secret-nas.corp.example"
        let cases: [(DeviceConnectionObservation, OperationOutcome, String?)] = [
            (.init(reason: .reachable, interfaceType: .wifi), .success, nil),
            (.init(reason: .refused, interfaceType: .wifi), .failure, "refused"),
            (.init(reason: .timedOut, interfaceType: .other, viaTunnel: true), .timedOut, "timedOut"),
            (.init(reason: .nameUnresolved), .failure, "nameUnresolved")
        ]
        for (observation, outcome, code) in cases {
            let result = await DeviceConnectionCheck(host: host, port: 445, probe: Fixed(observation: observation)).run(context: .init())
            XCTAssertEqual(result.outcome, outcome, observation.reason.rawValue)
            XCTAssertEqual(result.error?.code, code)
            XCTAssertEqual(result.after.values[.errorCode], observation.reason.rawValue)
            XCTAssertEqual(result.after.values[.networkStatus], observation.viaTunnel ? "active" : "inactive")
            let json = String(decoding: try JSONEncoder().encode(result), as: UTF8.self)
            XCTAssertFalse(json.contains("secret-nas"))
            XCTAssertFalse(json.contains("445"))
        }
        let tunnel = await DeviceConnectionCheck(host: host, port: 445,
            probe: Fixed(observation: .init(reason: .timedOut, interfaceType: .other, viaTunnel: true))).run(context: .init())
        XCTAssertEqual(tunnel.nextStep, NextStep.verifyVPN.rawValue)
        let invalid = await DeviceConnectionCheck(host: "", port: 445, probe: Fixed(observation: .init(reason: .reachable))).run(context: .init())
        XCTAssertEqual(invalid.outcome, .skipped)
        XCTAssertEqual(invalid.after.values[.errorCode], "invalidInput")
    }
    /// A listener bound to IPv4 loopback only; "localhost" resolves to ::1 and 127.0.0.1, so the
    /// IPv6 attempt is refused while IPv4 connects. Both verdicts must survive aggregation.
    func testMixedAddressFamiliesKeepBothVerdicts() async throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let listener = try NWListener(using: parameters)
        listener.newConnectionHandler = { connection in connection.cancel() }
        let ready = expectation(description: "listener ready")
        listener.stateUpdateHandler = { state in if case .ready = state { ready.fulfill() } }
        listener.start(queue: DispatchQueue(label: "NetUnstick.MixedFamilies"))
        await fulfillment(of: [ready], timeout: 5)
        defer { listener.cancel() }
        let port = try XCTUnwrap(listener.port?.rawValue)
        let localhost = await DeviceNameResolver.resolve("localhost", timeout: 3)
        let resolved = try XCTUnwrap(localhost)
        XCTAssertTrue(resolved.contains { $0.family == .ipv4 })
        XCTAssertTrue(resolved.contains { $0.family == .ipv6 })
        let missing = await DeviceNameResolver.resolve("no-such-host.invalid", timeout: 4)
        XCTAssertNil(missing)
        let observation = await SystemDeviceConnectionProbe().probe(host: "localhost", port: port, timeout: .seconds(3))
        XCTAssertEqual(observation.reason, .reachable)
        XCTAssertEqual(observation.ipv4, .reachable)
        XCTAssertEqual(observation.ipv6, .refused)
        XCTAssertEqual(observation.interfaceType, .loopback)
    }

    func testAggregationPrefersAnAnsweringPeerAndCapsAddressesPerFamily() {
        let mixed = SystemDeviceConnectionProbe.aggregate([
            AddressAttempt(family: .ipv6, reason: .unreachable, interfaceType: .wifi, viaTunnel: false),
            AddressAttempt(family: .ipv4, reason: .refused, interfaceType: .wifi, viaTunnel: false)
        ])
        XCTAssertEqual(mixed.reason, .refused)
        XCTAssertEqual(mixed.ipv4, .refused)
        XCTAssertEqual(mixed.ipv6, .unreachable)
        let silent = SystemDeviceConnectionProbe.aggregate([
            AddressAttempt(family: .ipv6, reason: .unreachable, interfaceType: nil, viaTunnel: false),
            AddressAttempt(family: .ipv4, reason: .timedOut, interfaceType: .ethernet, viaTunnel: true)
        ])
        XCTAssertEqual(silent.reason, .timedOut)
        XCTAssertEqual(silent.interfaceType, .ethernet)
        XCTAssertTrue(silent.viaTunnel)
        XCTAssertEqual(silent.ipv4, .timedOut)
        XCTAssertEqual(silent.ipv6, .unreachable)
        let many = (0..<6).map { ResolvedAddress(family: .ipv6, literal: "fd00::\($0)") } + [ResolvedAddress(family: .ipv4, literal: "192.0.2.1")]
        let selected = SystemDeviceConnectionProbe.select(many)
        XCTAssertEqual(selected.filter { $0.family == .ipv6 }.count, SystemDeviceConnectionProbe.maximumAddressesPerFamily)
        XCTAssertEqual(selected.filter { $0.family == .ipv4 }.count, 1)
        XCTAssertEqual(SystemDeviceConnectionProbe.aggregate([]).reason, .failed)
    }

    func testCheckPublishesPerFamilyCodesWithoutAddresses() async throws {
        struct Fixed: DeviceConnectionProbing {
            let observation: DeviceConnectionObservation
            func probe(host: String, port: UInt16, timeout: Duration) async -> DeviceConnectionObservation { observation }
        }
        let split = await DeviceConnectionCheck(host: "nas.example.internal", port: 445,
            probe: Fixed(observation: .init(reason: .reachable, interfaceType: .wifi, ipv4: .reachable, ipv6: .unreachable))).run(context: .init())
        XCTAssertEqual(split.outcome, .success)
        XCTAssertEqual(split.after.values[.ipv4Result], "reachable")
        XCTAssertEqual(split.after.values[.ipv6Result], "unreachable")
        let json = String(decoding: try JSONEncoder().encode(split), as: UTF8.self)
        XCTAssertFalse(json.contains("nas.example"))
        XCTAssertFalse(json.contains("::"))
        let single = await DeviceConnectionCheck(host: "nas.example.internal", port: 445,
            probe: Fixed(observation: .init(reason: .refused, interfaceType: .wifi, ipv4: .refused))).run(context: .init())
        XCTAssertEqual(single.after.values[.ipv4Result], "refused")
        XCTAssertNil(single.after.values[.ipv6Result])
    }
    func testSMBSessionIsClassifiedByExitStatusAndDrivesVerdict() async throws {
        XCTAssertEqual(SMBSessionOutcome.classify(exitStatus: 0), .sharesListed)
        XCTAssertEqual(SMBSessionOutcome.classify(exitStatus: 77), .authRejected)
        XCTAssertEqual(SMBSessionOutcome.classify(exitStatus: 68), .sessionFailed)
        XCTAssertEqual(SMBSessionOutcome.classify(exitStatus: 1), .otherExit)
        XCTAssertEqual(SMBSessionOutcome.classify(exitStatus: 69), .otherExit)
        struct Fixed: DeviceConnectionProbing {
            let observation: DeviceConnectionObservation
            func probe(host: String, port: UInt16, timeout: Duration) async -> DeviceConnectionObservation { observation }
        }
        // Port answers but the server drops the SMB 3 negotiate of this newer client: the step is the SMB 2 workaround.
        let blocked = await DeviceConnectionCheck(host: "nas.example.internal", port: 445, probe: Fixed(observation:
            .init(reason: .reachable, interfaceType: .wifi, ipv4: .reachable, smb: .sessionFailed, firewallEnabled: true, contentFilterActive: true))).run(context: .init())
        XCTAssertEqual(blocked.outcome, .failure)
        XCTAssertEqual(blocked.error?.code, "smbSessionFailed")
        XCTAssertEqual(blocked.after.values[.errorCode], "reachable")
        XCTAssertEqual(blocked.after.values[.smbResult], "sessionFailed")
        XCTAssertEqual(blocked.after.values[.firewallStatus], "active")
        XCTAssertEqual(blocked.after.values[.contentFilterStatus], "active")
        XCTAssertEqual(blocked.nextStep, NextStep.limitSMBToVersion2.rawValue)
        // Session negotiated, guest rejected: the service works and only a login is missing.
        let login = await DeviceConnectionCheck(host: "nas.example.internal", port: 445, probe: Fixed(observation:
            .init(reason: .reachable, interfaceType: .wifi, ipv4: .reachable, smb: .authRejected))).run(context: .init())
        XCTAssertEqual(login.outcome, .success)
        XCTAssertEqual(login.after.values[.smbResult], "authRejected")
        XCTAssertNil(login.after.values[.firewallStatus])
        XCTAssertEqual(login.nextStep, NextStep.connectAsAccount.rawValue)
        // Session failed without any filter: same verdict and step, the filter only adds a note.
        let other = await DeviceConnectionCheck(host: "nas.example.internal", port: 445, probe: Fixed(observation:
            .init(reason: .reachable, interfaceType: .wifi, ipv4: .reachable, smb: .sessionFailed, firewallEnabled: false, contentFilterActive: false))).run(context: .init())
        XCTAssertEqual(other.outcome, .failure)
        XCTAssertEqual(other.nextStep, NextStep.limitSMBToVersion2.rawValue)
        // A client that timed out or exited oddly is not a verdict about the server.
        let slow = await DeviceConnectionCheck(host: "nas.example.internal", port: 445, probe: Fixed(observation:
            .init(reason: .reachable, interfaceType: .wifi, ipv4: .reachable, smb: .timedOut))).run(context: .init())
        XCTAssertEqual(slow.outcome, .success)
        XCTAssertEqual(slow.after.values[.smbResult], "timedOut")
        XCTAssertEqual(slow.nextStep, NextStep.retryCheck.rawValue)
        let json = String(decoding: try JSONEncoder().encode(blocked), as: UTF8.self)
        XCTAssertFalse(json.contains("nas.example"))
    }

    /// The SMB probe runs only for port 445 and only after the port answered; the local filter is read
    /// only when the session failed.
    func testSystemProbeAsksTheSMBClientOnlyForPort445() async throws {
        actor Calls { var smb = 0; var filters = 0; func smbCalled() { smb += 1 }; func filtersCalled() { filters += 1 } }
        let calls = Calls()
        struct SMB: SMBSessionProbing {
            let calls: Calls; let outcome: SMBSessionOutcome
            func probe(host: String) async -> SMBSessionOutcome { await calls.smbCalled(); return outcome }
        }
        struct Filters: ContentFilterProbing {
            let calls: Calls
            func observe() async -> ContentFilterObservation {
                await calls.filtersCalled()
                return .init(activeFilters: 1, attachedSockets: 4, firewallEnabled: true, blockAllIncoming: false)
            }
        }
        let (listener, port) = try listen()
        defer { listener.cancel() }
        // Any other port: reachable, no SMB probe, no filter read.
        let plain = await SystemDeviceConnectionProbe(smb: SMB(calls: calls, outcome: .sessionFailed), filters: Filters(calls: calls))
            .probe(host: "127.0.0.1", port: port, timeout: .seconds(3))
        XCTAssertEqual(plain.reason, .reachable)
        XCTAssertNil(plain.smb)
        let afterPlain = await calls.smb
        XCTAssertEqual(afterPlain, 0)
        // Port 445 on loopback answers only where file sharing is on; the probe must then consult the client.
        let smb = await SystemDeviceConnectionProbe(smb: SMB(calls: calls, outcome: .sessionFailed), filters: Filters(calls: calls))
            .probe(host: "127.0.0.1", port: 445, timeout: .seconds(3))
        let smbCalls = await calls.smb
        let filterCalls = await calls.filters
        if smb.reason == .reachable {
            XCTAssertEqual(smb.smb, .sessionFailed)
            XCTAssertEqual(smb.firewallEnabled, true)
            XCTAssertEqual(smb.contentFilterActive, true)
            XCTAssertEqual(smbCalls, 1)
            XCTAssertEqual(filterCalls, 1)
        } else {
            XCTAssertNil(smb.smb)
            XCTAssertEqual(smbCalls, 0)
        }
    }
}
