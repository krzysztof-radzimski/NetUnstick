import XCTest
import NetUnstickNetwork

final class IPPrefixTests: XCTestCase {
    func testNetstatAbbreviationsNormalizeToMaskedNetworks() {
        let cases: [(String, String)] = [
            ("127", "127.0.0.0/8"), ("192.168.1", "192.168.1.0/24"), ("224.0.0/4", "224.0.0.0/4"),
            ("192.168.1/32", "192.168.1.0/32"), ("192.168.1.2/31", "192.168.1.2/31"), ("192.168.1.33", "192.168.1.33/32"),
            ("192.168.1.77/24", "192.168.1.0/24"), ("0.0.0.0/0", "0.0.0.0/0"), ("255.255.255.255/32", "255.255.255.255/32"),
            ("fe80::%utun0/64", "fe80::/64"), ("fe80::fd1a:6a11%utun0", "fe80::fd1a:6a11/128"), ("::/0", "::/0"),
            ("2001:db8:1::/64", "2001:db8:1::/64"), ("ff02::%en0/32", "ff02::/32")
        ]
        for (input, expected) in cases {
            XCTAssertEqual(IPPrefix(input)?.cidr, expected, input)
        }
        for invalid in ["", "/24", "192.168.1.0/33", "300.1.1.1", "abc", "1.2.3.4.5", "192.168..1", "fe80::/129", "10.0.0.0/-1", "10.0.0.0/2x"] {
            XCTAssertNil(IPPrefix(invalid), invalid)
        }
    }

    func testHostAddressesRejectAbbreviatedNetworks() {
        XCTAssertEqual(IPPrefix(address: "10.1.2.3")?.cidr, "10.1.2.3/32")
        XCTAssertEqual(IPPrefix(address: "fe80::1%en0")?.prefix, 128)
        XCTAssertNil(IPPrefix(address: "192.168.1"))
        XCTAssertNil(IPPrefix(address: "10.0.0.0/8"))
    }

    func testContainmentAndClassification() throws {
        let lan = try XCTUnwrap(IPPrefix("192.168.1"))
        let split = try XCTUnwrap(IPPrefix("192.168.1.32/27"))
        let wholeLAN = try XCTUnwrap(IPPrefix("192.168.1.0/24"))
        XCTAssertTrue(lan.contains(split))
        XCTAssertFalse(split.contains(lan))
        XCTAssertTrue(lan.contains(wholeLAN), "Equal prefixes contain each other")
        XCTAssertTrue(lan.contains(address: "192.168.1.40"))
        XCTAssertFalse(lan.contains(address: "192.168.2.40"))
        XCTAssertFalse(lan.contains(try XCTUnwrap(IPPrefix("2001:db8::/32"))), "Families never mix")
        XCTAssertTrue(try XCTUnwrap(IPPrefix("fe80::%utun3/64")).isLinkLocal)
        XCTAssertTrue(try XCTUnwrap(IPPrefix("169.254")).isLinkLocal)
        XCTAssertFalse(try XCTUnwrap(IPPrefix("169.0.0.0/8")).isLinkLocal)
        XCTAssertTrue(try XCTUnwrap(IPPrefix("224.0.0.251")).isMulticast)
        XCTAssertTrue(try XCTUnwrap(IPPrefix("ff02::fb")).isMulticast)
        XCTAssertTrue(try XCTUnwrap(IPPrefix("127")).isLoopback)
        XCTAssertTrue(try XCTUnwrap(IPPrefix("::1")).isLoopback)
        for text in ["10.0.0.0/8", "172.16.0.0/12", "172.31.255.0/24", "192.168.44.32/27", "169.254.0.0/16"] {
            XCTAssertTrue(try XCTUnwrap(IPPrefix(text)).isPrivateIPv4, text)
        }
        for text in ["8.8.8.0/24", "172.32.0.0/12", "10.0.0.0/7", "192.168.0.0/15", "2001:db8::/32"] {
            XCTAssertFalse(try XCTUnwrap(IPPrefix(text)).isPrivateIPv4, text)
        }
        let sorted = ["192.168.1.128/25", "192.168.1/32", "192.168.1.2/31", "10.0.0.0/8"].compactMap { IPPrefix($0) }.sorted()
        XCTAssertEqual(sorted.map(\.cidr), ["10.0.0.0/8", "192.168.1.0/32", "192.168.1.2/31", "192.168.1.128/25"])
    }
}
