import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

private func XCTUnwrap<T>(_ value: T?, _ message: String = "missing value") throws -> T {
    guard let value else { fatalError(message) }; return value
}
private func XCTAssertTrue(_ condition: @autoclosure () -> Bool, _ message: String = "assertion failed") { precondition(condition(), message) }
private func XCTAssertFalse(_ condition: @autoclosure () -> Bool, _ message: String = "assertion failed") { precondition(!condition(), message) }
private func XCTAssertEqual<T: Equatable>(_ a: @autoclosure () -> T, _ b: @autoclosure () -> T) { precondition(a() == b(), "values differ: \(a()) != \(b())") }
private func XCTAssertEqual(_ a: Double, _ b: Double, accuracy: Double) { precondition(abs(a-b) <= accuracy, "values differ: \(a) != \(b)") }
private func XCTAssertLessThan(_ a: Double, _ b: Double) { precondition(a < b, "\(a) is not less than \(b)") }
private func XCTAssertGreaterThan(_ a: Double, _ b: Double, _ message: String) { precondition(a > b, "\(message): \(a) <= \(b)") }

final class AppIconAssetTests {
    private let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["NETUNSTICK_ICON_TEST_ROOT"] ?? FileManager.default.currentDirectoryPath)
    private let sizes = [16, 32, 128, 256, 512]
    private let variants = ["Default", "Dark", "MonoTinted", "ClearLight", "ClearDark"]

    private func image(_ url: URL) throws -> CGImage {
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil), "Missing image: \(url.path)")
        XCTAssertEqual(CGImageSourceGetType(source) as String?, UTType.png.identifier)
        return try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
    }

    private func pixels(_ image: CGImage) throws -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let ok = bytes.withUnsafeMutableBytes { raw -> Bool in
            guard let pointer = raw.baseAddress,
                  let context = CGContext(data: pointer, width: image.width, height: image.height,
                                          bitsPerComponent: 8, bytesPerRow: image.width * 4,
                                          space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            return true
        }
        XCTAssertTrue(ok)
        return bytes
    }

    private func pixel(_ bytes: [UInt8], _ size: Int, _ x: Int, _ y: Int) -> [Double] {
        let i = (y * size + x) * 4
        return (0..<4).map { Double(bytes[i + $0]) / 255 }
    }
    private func luminance(_ pixel: [Double], on background: [Double]) -> Double {
        let alpha = pixel[3]
        let rgb = (0..<3).map { index -> Double in
            let channel = pixel[index] + background[index] * (1-alpha)
            return channel <= 0.04045 ? channel / 12.92 : pow((channel + 0.055)/1.055, 2.4)
        }
        return 0.2126*rgb[0] + 0.7152*rgb[1] + 0.0722*rgb[2]
    }
    private func contrast(_ a: Double, _ b: Double) -> Double { (max(a,b)+0.05)/(min(a,b)+0.05) }

    func testAllMacSlotsHaveCorrectDimensionsAndAlpha() throws {
        let set = root.appendingPathComponent("NetUnstick/Resources/Assets.xcassets/AppIcon.appiconset")
        let json = try Data(contentsOf: set.appendingPathComponent("Contents.json"))
        let manifest = try XCTUnwrap(JSONSerialization.jsonObject(with: json) as? [String: Any])
        let rows = try XCTUnwrap(manifest["images"] as? [[String: String]])
        XCTAssertEqual(rows.count, 10)
        for pt in sizes { for scale in [1,2] {
            let name = "AppIcon-\(pt)@\(scale)x.png"
            XCTAssertEqual(rows.filter { $0["filename"] == name && $0["size"] == "\(pt)x\(pt)" && $0["scale"] == "\(scale)x" && $0["idiom"] == "mac" }.count, 1)
            let icon = try image(set.appendingPathComponent(name))
            XCTAssertEqual(icon.width, pt*scale); XCTAssertEqual(icon.height, pt*scale)
            XCTAssertFalse([CGImageAlphaInfo.none, .noneSkipFirst, .noneSkipLast].contains(icon.alphaInfo))
            let data = try pixels(icon)
            XCTAssertEqual(pixel(data, icon.width, icon.width/2, icon.height/2)[3], 1, accuracy: 0.01)
        } }
    }

    func testVariantSourcesAndReadableSilhouette() throws {
        let backgrounds: [[Double]] = [[0.945,0.961,0.969], [0.075,0.149,0.196]]
        for variant in variants {
            let folder = root.appendingPathComponent("Design/AppIcon/Sources/\(variant)")
            for layer in ["background", "route", "nodes"] {
                let svg = try String(contentsOf: folder.appendingPathComponent("\(layer).svg"), encoding: .utf8)
                XCTAssertFalse(svg.contains("<text")); XCTAssertFalse(svg.contains("font"))
                XCTAssertTrue(svg.contains("viewBox=\"0 0 1024 1024\""))
            }
            let sides = variant == "ClearLight" ? [0] : variant == "ClearDark" ? [1] : [0,1]
            for size in [16, 32, 64, 128, 512, 1024] {
                let icon = try image(root.appendingPathComponent("Design/AppIcon/Generated/\(variant)/\(size).png"))
                XCTAssertEqual(icon.width, size); XCTAssertEqual(icon.height, size)
                let data = try pixels(icon)
                let corner = pixel(data, size, max(0,size/32), max(0,size/32))
                for side in sides {
                    let backdrop = backgrounds[side]
                    let bg = luminance(corner, on: backdrop)
                    for (x,y) in [(230,330),(454,690),(790,330)] {
                        let node = pixel(data, size, min(size-1,x*size/1024), min(size-1,y*size/1024))
                        let ratio = contrast(luminance(node, on: backdrop), bg)
                        XCTAssertGreaterThan(ratio, 3.0, "\(variant) \(size) px node contrast on side \(side)")
                    }
                    if size >= 32 {
                        let route = pixel(data, size, 345*size/1024, 500*size/1024)
                        XCTAssertGreaterThan(contrast(luminance(route, on: backdrop), bg), 2.5,
                                             "\(variant) \(size) px route contrast on side \(side)")
                    }
                }
                if variant.hasPrefix("Clear") { XCTAssertLessThan(corner[3], 0.01) }
                else { XCTAssertEqual(corner[3], 1, accuracy: 0.01) }
            }
        }
    }
}

do {
    let tests = AppIconAssetTests()
    try tests.testAllMacSlotsHaveCorrectDimensionsAndAlpha()
    print("PASS: 10 macOS slots, dimensions, alpha and pixels")
    try tests.testVariantSourcesAndReadableSilhouette()
    print("PASS: 5 layered variants, no text, contrast at 16–1024 px")
} catch { fputs("FAIL: \(error)\n", stderr); exit(1) }
