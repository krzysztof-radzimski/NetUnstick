import XCTest
import NetUnstickNetwork

/// Run separately: NETUNSTICK_READ_ONLY_SMOKE=1 swift test --filter ReadOnlySmokeTests
final class ReadOnlySmokeTests: XCTestCase {
    func testHostObservationWritesOnlySanitizedJSON() async throws {
        guard ProcessInfo.processInfo.environment["NETUNSTICK_READ_ONLY_SMOKE"] == "1" else {
            throw XCTSkip("Set NETUNSTICK_READ_ONLY_SMOKE=1 for the separate macOS read-only smoke test")
        }
        let raw = await SystemNetworkStateCollector().collect()
        let assessment = VPNStateDetector().assess(raw)
        XCTAssertTrue([VPNState.active, .inactive, .unknown].contains(assessment.state))
        if !raw.errors.isEmpty { XCTAssertEqual(assessment.state, .unknown) }
        let safe = SanitizedNetworkSnapshot(raw: raw)
        let report = try JSONEncoder().encode(safe)
        let packageDirectory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        let output = packageDirectory.appendingPathComponent(".build/netunstick-smoke-redacted.json")
        try report.write(to: output, options: .atomic)
        let saved = try Data(contentsOf: output)
        XCTAssertEqual(saved, report)
        let text = String(decoding: saved, as: UTF8.self)
        for address in raw.interfaces.flatMap(\.addresses) where !address.isEmpty {
            XCTAssertFalse(text.contains(address))
        }
        for resolver in raw.resolvers {
            if let domain = resolver.domain { XCTAssertFalse(text.contains(domain)) }
            for domain in resolver.searchDomains { XCTAssertFalse(text.contains(domain)) }
        }
        for item in raw.interfaces { XCTAssertFalse(text.contains("\"\(item.name)\"")) }
    }
}
