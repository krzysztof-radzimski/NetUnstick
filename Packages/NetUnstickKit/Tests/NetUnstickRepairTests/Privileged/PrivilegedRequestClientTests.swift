import XCTest
import NetUnstickRepair
import NetUnstickNetwork

import NetUnstickCore

private struct FakeTransport: PrivilegedRequestTransport {
    let response: Data?
    let error: Error?
    func perform(_ request: Data, completion: @escaping (Data?, Error?) -> Void) {
        completion(response, error)
        completion(response, error) // duplicate disconnect must not call the app twice
    }
}
private struct SilentTransport: PrivilegedRequestTransport {
    func perform(_ request: Data, completion: @escaping (Data?, Error?) -> Void) {}
}
final class PrivilegedRequestClientTests: XCTestCase {
    func testSuccessDisconnectPermissionAndTimeout() async throws {
        let sample = await PrivilegedRepairExecutor(collector: ClientSnapshot(), dhcp: ClientDHCP(), runner: ClientRunner())
            .perform(.init(action: .renewDHCP(interface: "en0")))
        let encoded = try JSONEncoder().encode(sample)
        for (transport, expected) in [(FakeTransport(response: encoded, error: nil), PrivilegedCode.success),
                                      (FakeTransport(response: nil, error: NSError(domain: "xpc", code: 1)), .disconnected),
                                      (FakeTransport(response: nil, error: NSError(domain: NSCocoaErrorDomain, code: NSFileReadNoPermissionError)), .permissionDenied)] {
            let expectation = expectation(description: "single reply")
            PrivilegedRequestClient.perform(.renewDHCP(interface: "en0"), transport: transport, timeout: 0.02) {
                XCTAssertEqual($0.code, expected); expectation.fulfill()
            }
            await fulfillment(of: [expectation], timeout: 1)
        }
        let expectation = expectation(description: "timeout")
        PrivilegedRequestClient.perform(.renewDHCP(interface: "en0"), transport: SilentTransport(), timeout: 0.02) {
            XCTAssertEqual($0.code, .timedOut); expectation.fulfill()
        }
        await fulfillment(of: [expectation], timeout: 1)
        XCTAssertEqual(PrivilegedRequestClient.failure(.approvalRequired).result.outcome, .permissionDenied)
        XCTAssertEqual(PrivilegedRequestClient.timeout(for: .handshake), 10)
        XCTAssertEqual(PrivilegedRequestClient.timeout(for: .renewDHCP(interface: "en0")), 30)
        let eight = (0..<8).map { PrivilegedRouteTarget(destination: "192.168.44.\($0 * 2)", prefix: 31, interface: "utun4") }
        XCTAssertEqual(PrivilegedRequestClient.timeout(for: .removeStaleTunnelRoutes(routes: eight)), 70)
    }

    func testHelperGuidanceSurvivesStructuredResultsAndJSONRoundTrip() throws {
        let cases: [(PrivilegedCode, String)] = [
            (.notRegistered, "Zarejestruj helper jawnym przyciskiem przed naprawą."),
            (.approvalRequired, "Zatwierdź helper w Elementach logowania."),
            (.notFound, "Zainstaluj ponownie podpisany pakiet aplikacji."),
            (.timedOut, "Sprawdź stan VPN i spróbuj później."),
            (.permissionDenied, "Sprawdź uprawnienia helpera i zgodę systemową."),
            (.disconnected, "Uruchom ponownie aplikację i sprawdź status helpera.")
        ]
        for (code, guidance) in cases {
            let reply = PrivilegedRequestClient.failure(code)
            XCTAssertEqual(reply.result.nextStep, guidance, code.rawValue)
            let encoded = try JSONEncoder().encode(reply)
            let restored = try JSONDecoder().decode(PrivilegedReply.self, from: encoded)
            XCTAssertEqual(restored.code, code)
            XCTAssertEqual(restored.result, reply.result)
            XCTAssertEqual(restored.result.nextStep, guidance, code.rawValue)
        }
    }

    func testUnknownHelperGuidanceStillRedactsSecretsOnCreationAndDecode() throws {
        let sensitive = "Zarejestruj helper dla vpn.private.corp token=secret-helper-token-123"
        let sample = PrivilegedRequestClient.failure(.notRegistered)
        let result = try OperationResult(operationID: "helper_guidance_privacy", name: "privileged_repair",
            kind: .repair, startedAt: sample.result.startedAt, endedAt: sample.result.endedAt,
            outcome: .permissionDenied, error: sample.result.error, nextStep: sensitive)
        XCTAssertEqual(result.nextStep, NextStep.reviewDetails.rawValue)
        let encoded = try JSONEncoder().encode(result)
        let text = String(decoding: encoded, as: UTF8.self)
        XCTAssertFalse(text.contains("vpn.private.corp"))
        XCTAssertFalse(text.contains("secret-helper-token-123"))

        // Persisted or external data crosses the same boundary as a newly created result.
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object["nextStep"] = sensitive
        let untrusted = try JSONSerialization.data(withJSONObject: object)
        let decoded = try JSONDecoder().decode(OperationResult.self, from: untrusted)
        XCTAssertEqual(decoded.nextStep, NextStep.reviewDetails.rawValue)
        let sanitized = try JSONEncoder().encode(decoded)
        let sanitizedText = String(decoding: sanitized, as: UTF8.self)
        XCTAssertFalse(sanitizedText.contains("vpn.private.corp"))
        XCTAssertFalse(sanitizedText.contains("secret-helper-token-123"))
    }
}
private struct ClientSnapshot: NetUnstickNetwork.NetworkStateCollecting {
    func collect() async -> NetUnstickNetwork.RawNetworkSnapshot {
        .init(startedAt: Date(), endedAt: Date(), path: .init(status: "satisfied", availableInterfaces: ["en0"],
            selectedInterfaces: ["en0"], supportsDNS: true, supportsIPv4: true, supportsIPv6: false, gateways: []),
            interfaces: [.init(name: "en0", type: "wifi", isUp: true, addresses: [])], routes: [], resolvers: [], proxy: nil,
            dynamicStoreVPNKeys: [], errors: [])
    }
}
private struct ClientDHCP: DHCPConfigurationChecking {
    func configuredInterfaces() -> Set<String> { ["en0"] }
    func refresh(_ name: String) -> Bool { true }
}
private struct ClientRunner: PrivilegedCommandRunning {
    func run(executable: String, arguments: [String]) async throws {}
}
