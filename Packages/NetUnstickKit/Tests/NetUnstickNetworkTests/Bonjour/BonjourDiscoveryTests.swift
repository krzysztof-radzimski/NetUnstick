import Foundation
import Network
import XCTest
import NetUnstickCore
import NetUnstickNetwork

private struct FixedBrowser: BonjourBrowsing {
    let answers: [BonjourService: BonjourObservation]
    func browse(_ service: BonjourService, timeout: Duration) async -> BonjourObservation {
        answers[service] ?? .init(count: 0, reason: .noServices)
    }
}
private struct SlowBrowser: BonjourBrowsing {
    func browse(_ service: BonjourService, timeout: Duration) async -> BonjourObservation {
        do { try await Task.sleep(for: .seconds(5)) }
        catch { return .init(count: 0, reason: .cancelled) }
        return .init(count: 0, reason: .noServices)
    }
}

final class BonjourDiscoveryTests: XCTestCase {
    private func snapshot(physical: Bool = true, route: Bool = true) -> RawNetworkSnapshot {
        let now = Date()
        return RawNetworkSnapshot(startedAt: now, endedAt: now,
            path: RawPathState(status: "satisfied", availableInterfaces: ["en0"], selectedInterfaces: ["en0"],
                supportsDNS: true, supportsIPv4: true, supportsIPv6: false, gateways: []),
            interfaces: physical ? [.init(name: "en0", type: "wifi", isUp: true, addresses: ["192.0.2.2"])] : [],
            routes: route ? [.init(destination: "192.0.2.0/24", gateway: nil, interfaceName: "en0", isDefault: false, isLocal: true)] : [],
            resolvers: [], proxy: nil, dynamicStoreVPNKeys: [], errors: [])
    }
    func testCountsOnlyAndNoServicesIsInconclusive() async throws {
        let browser = FixedBrowser(answers: [.airplay: .init(count: 2, reason: .servicesFound),
                                              .raop: .init(count: 1, reason: .servicesFound)])
        let result = await BonjourDiscoveryChecking(snapshot: snapshot(), browser: browser).run()
        XCTAssertEqual(result.outcome, .success)
        XCTAssertEqual(result.after.values[.airplayCount], "2")
        XCTAssertEqual(result.after.values[.raopCount], "1")
        XCTAssertEqual(result.after.values[.interfaceType], "wifi")
        let json = String(decoding: try JSONEncoder().encode(result), as: UTF8.self)
        XCTAssertFalse(json.contains("Apple TV"))
        XCTAssertFalse(json.contains("192.0.2"))
        XCTAssertFalse(json.contains("en0"))
        let empty = await BonjourDiscoveryChecking(snapshot: snapshot(), browser: FixedBrowser(answers: [:])).run()
        XCTAssertEqual(empty.outcome, .skipped)
        XCTAssertEqual(empty.after.values[.errorCode], BonjourReason.noServices.rawValue)
    }
    func testPermissionAndBrowserFailuresStayDistinct() async {
        for (reason, outcome) in [(BonjourReason.permissionDenied, OperationOutcome.permissionDenied),
                                  (.browserFailed, .failure), (.timedOut, .timedOut)] {
            let browser = FixedBrowser(answers: [.airplay: .init(count: 0, reason: reason)])
            let result = await BonjourDiscoveryChecking(snapshot: snapshot(), browser: browser).run()
            XCTAssertEqual(result.outcome, outcome)
            XCTAssertEqual(result.error?.code, reason.rawValue)
        }
        let permission = await BonjourPermissionCheck(observation: .init(count: 0, reason: .permissionDenied)).run()
        XCTAssertEqual(permission.outcome, .permissionDenied)
        let noPhysical = await LocalMulticastPathCheck(snapshot: snapshot(physical: false)).run()
        let noRoute = await LocalMulticastPathCheck(snapshot: snapshot(route: false)).run()
        XCTAssertEqual(noPhysical.after.values[.errorCode], BonjourReason.noPhysicalInterface.rawValue)
        XCTAssertEqual(noRoute.after.values[.errorCode], BonjourReason.noLocalPath.rawValue)
    }
    func testDiscoveryCancellationStopsBeforeSecondService() async {
        let task = Task { await BonjourDiscoveryChecking(snapshot: snapshot(), browser: SlowBrowser()).run() }
        task.cancel()
        let result = await task.value
        XCTAssertEqual(result.outcome, .cancelled)
        XCTAssertEqual(result.after.values[.errorCode], BonjourReason.cancelled.rawValue)
    }

    /// Self-contained live test: an invented local service, no AirPlay connection or receiver.
    func testLocalAdvertiserHarness() async throws {
        guard ProcessInfo.processInfo.environment["NETUNSTICK_BONJOUR_LIVE"] == "1" else {
            throw XCTSkip("Set NETUNSTICK_BONJOUR_LIVE=1 for local-network harness")
        }
        let fixtureName = "NetUnstickFixture-\(UUID().uuidString)"
        let listener = try NWListener(using: .tcp, on: .any)
        listener.service = NWListener.Service(name: fixtureName, type: BonjourService.airplay.rawValue)
        listener.newConnectionHandler = { connection in connection.cancel() }
        let (stream, continuation) = AsyncStream.makeStream(of: (Bool, String?).self, bufferingPolicy: .bufferingNewest(1))
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready: continuation.yield((true, nil))
            case .failed(let error): continuation.yield((false, "\(error)"))
            default: break
            }
        }
        listener.start(queue: DispatchQueue(label: "NetUnstick.Fixture"))
        defer { listener.cancel(); continuation.finish() }
        let timer = Task {
            do { try await Task.sleep(for: .seconds(3)); continuation.yield((false, nil)) }
            catch { /* The listener completed before the deadline. */ }
        }
        var iterator = stream.makeAsyncIterator()
        let (ready, startupError) = await iterator.next() ?? (false, nil)
        timer.cancel()
        if let startupError {
            XCTFail("Local advertiser failed to start: \(startupError)")
            return
        }
        guard ready else { throw XCTSkip("Local advertiser timed out on this host") }
        let fixtureBrowser = NWBrowser(for: .bonjour(type: BonjourService.airplay.rawValue, domain: nil), using: .tcp)
        let (foundStream, foundContinuation) = AsyncStream.makeStream(of: Bool.self, bufferingPolicy: .bufferingNewest(1))
        fixtureBrowser.browseResultsChangedHandler = { results, _ in
            let found = results.contains { result in
                guard case let .service(name, _, _, _) = result.endpoint else { return false }
                return name == fixtureName
            }
            if found { foundContinuation.yield(true) }
        }
        fixtureBrowser.stateUpdateHandler = { state in
            if case .failed = state { foundContinuation.yield(false) }
        }
        fixtureBrowser.start(queue: DispatchQueue(label: "NetUnstick.FixtureBrowser"))
        defer { fixtureBrowser.cancel(); foundContinuation.finish() }
        let discoveryTimer = Task {
            do { try await Task.sleep(for: .seconds(3)); foundContinuation.yield(false) }
            catch { /* The fixture was found before the deadline. */ }
        }
        var foundIterator = foundStream.makeAsyncIterator()
        let foundFixture = await foundIterator.next() ?? false
        discoveryTimer.cancel()
        guard foundFixture else {
            throw XCTSkip("Local-network permission or mDNS visibility unavailable for the fixture")
        }
        let observed = await SystemBonjourBrowser().browse(.airplay, timeout: .seconds(3))
        XCTAssertEqual(observed.reason, .servicesFound)
        XCTAssertGreaterThanOrEqual(observed.count, 1)
    }
}
