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
            .perform(.init(action: .refreshResolverCache))
        let encoded = try JSONEncoder().encode(sample)
        for (transport, expected) in [(FakeTransport(response: encoded, error: nil), PrivilegedCode.success),
                                      (FakeTransport(response: nil, error: NSError(domain: "xpc", code: 1)), .disconnected),
                                      (FakeTransport(response: nil, error: NSError(domain: NSCocoaErrorDomain, code: NSFileReadNoPermissionError)), .permissionDenied)] {
            let expectation = expectation(description: "single reply")
            PrivilegedRequestClient.perform(.refreshResolverCache, transport: transport, timeout: 0.02) {
                XCTAssertEqual($0.code, expected); expectation.fulfill()
            }
            await fulfillment(of: [expectation], timeout: 1)
        }
        let expectation = expectation(description: "timeout")
        PrivilegedRequestClient.perform(.refreshResolverCache, transport: SilentTransport(), timeout: 0.02) {
            XCTAssertEqual($0.code, .timedOut); expectation.fulfill()
        }
        await fulfillment(of: [expectation], timeout: 1)
        XCTAssertEqual(PrivilegedRequestClient.failure(.approvalRequired).result.outcome, .permissionDenied)
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
    func configuredInterfaces() -> Set<String> { [] }
    func refresh(_ name: String) -> Bool { false }
}
private struct ClientRunner: PrivilegedCommandRunning {
    func run(executable: String, arguments: [String]) async throws {}
}
