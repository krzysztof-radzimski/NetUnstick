import Foundation
import XCTest
import NetUnstickCore

final class EvidenceFamilyKeysTests: XCTestCase {
    func testFamilyVerdictsAcceptOnlyStableCodes() throws {
        let safe = EvidenceSanitizer.sanitize([.ipv4Result: .errorCode("reachable"), .ipv6Result: .errorCode("fd00::1"),
                                               .errorCode: .errorCode("refused")])
        XCTAssertEqual(safe.values[.ipv4Result], "reachable")
        XCTAssertNil(safe.values[.ipv6Result], "an address literal is not a reason code")
        XCTAssertEqual(safe.values[.errorCode], "refused")
        XCTAssertNil(EvidenceSanitizer.sanitize([.ipv4Result: .status(.passed)]).values[.ipv4Result])
        XCTAssertThrowsError(try JSONDecoder().decode(SafeEvidence.self, from: Data(#"{"ipv6Result":"fe80::1%en0"}"#.utf8)))
        let decoded = try JSONDecoder().decode(SafeEvidence.self, from: Data(#"{"ipv6Result":"unreachable","ipv4Result":"reachable"}"#.utf8))
        XCTAssertEqual(decoded.values[.ipv6Result], "unreachable")
        XCTAssertEqual(decoded.values[.ipv4Result], "reachable")
    }
}
