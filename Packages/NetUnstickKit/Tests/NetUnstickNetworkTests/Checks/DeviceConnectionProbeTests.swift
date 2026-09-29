import Foundation
import Network
import XCTest
import NetUnstickCore
import NetUnstickNetwork

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
              "interface=\(result.after.values[.interfaceType] ?? "-") viaTunnel=\(result.after.values[.networkStatus] == "active") next=\(result.nextStep ?? "-")")
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
}
