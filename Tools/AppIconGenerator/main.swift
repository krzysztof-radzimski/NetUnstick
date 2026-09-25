import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import CryptoKit
import CoreText

private let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
private let sources = root.appendingPathComponent("Design/AppIcon/Sources")
private let generated = root.appendingPathComponent("Design/AppIcon/Generated")
private let appIcon = root.appendingPathComponent("NetUnstick/Resources/Assets.xcassets/AppIcon.appiconset")
private let variants = ["Default", "Dark", "MonoTinted", "ClearLight", "ClearDark"]
private let points = [16, 32, 128, 256, 512]

private func fail(_ message: String) -> Never { fputs("AppIconGenerator: \(message)\n", stderr); exit(1) }
private func color(_ hex: String) -> CGColor {
    guard hex.count == 7, hex.first == "#", let rgb = UInt32(hex.dropFirst(), radix: 16) else { fail("invalid color \(hex)") }
    return CGColor(red: CGFloat((rgb >> 16) & 255) / 255, green: CGFloat((rgb >> 8) & 255) / 255,
                   blue: CGFloat(rgb & 255) / 255, alpha: 1)
}
private func attributes(_ tag: String) -> [String: String] {
    let regex = try! NSRegularExpression(pattern: "([a-z-]+)=\"([^\"]*)\"")
    let range = NSRange(tag.startIndex..., in: tag)
    var result: [String: String] = [:]
    for match in regex.matches(in: tag, range: range) {
        guard let k = Range(match.range(at: 1), in: tag), let v = Range(match.range(at: 2), in: tag) else { continue }
        result[String(tag[k])] = String(tag[v])
    }
    return result
}
private func drawLayer(_ url: URL, in context: CGContext) {
    guard let svg = try? String(contentsOf: url, encoding: .utf8), svg.contains("<svg") else { fail("missing SVG: \(url.path)") }
    let regex = try! NSRegularExpression(pattern: "<(rect|circle|path)\\b[^>]*>")
    let tags = regex.matches(in: svg, range: NSRange(svg.startIndex..., in: svg))
    guard !tags.isEmpty || url.lastPathComponent == "background.svg" else { fail("empty layer: \(url.path)") }
    for match in tags {
        let tag = String(svg[Range(match.range, in: svg)!]); let a = attributes(tag)
        let fill = a["fill"].map(color)
        let stroke = a["stroke"].map(color)
        let width = CGFloat(Double(a["stroke-width"] ?? "0") ?? 0)
        context.setLineWidth(width); context.setLineCap(.round); context.setLineJoin(.round)
        if let fill { context.setFillColor(fill) }
        if let stroke { context.setStrokeColor(stroke) }
        if tag.hasPrefix("<rect") {
            let rect = CGRect(x: Double(a["x"] ?? "0") ?? 0, y: Double(a["y"] ?? "0") ?? 0,
                              width: Double(a["width"] ?? "0") ?? 0, height: Double(a["height"] ?? "0") ?? 0)
            if fill != nil { context.fill(rect) }
        } else if tag.hasPrefix("<circle") {
            guard let cx = Double(a["cx"] ?? ""), let cy = Double(a["cy"] ?? ""), let r = Double(a["r"] ?? "") else { fail("invalid circle") }
            let rect = CGRect(x: cx-r, y: cy-r, width: 2*r, height: 2*r)
            if fill != nil { context.fillEllipse(in: rect) }
            if stroke != nil { context.strokeEllipse(in: rect) }
        } else {
            guard let d = a["d"] else { fail("path missing d") }
            let tokens = d.split(whereSeparator: { $0 == " " || $0 == "," }).map(String.init)
            var i = 0; let path = CGMutablePath()
            func number() -> CGFloat { guard i < tokens.count, let n = Double(tokens[i]) else { fail("invalid path number") }; i += 1; return n }
            while i < tokens.count {
                let op = tokens[i]; i += 1
                switch op {
                case "M": path.move(to: CGPoint(x: number(), y: number()))
                case "C":
                    let c1 = CGPoint(x: number(), y: number())
                    let c2 = CGPoint(x: number(), y: number())
                    let end = CGPoint(x: number(), y: number())
                    path.addCurve(to: end, control1: c1, control2: c2)
                default: fail("unsupported SVG path command \(op)")
                }
            }
            context.addPath(path)
            if fill != nil && stroke != nil { context.drawPath(using: .fillStroke) }
            else if stroke != nil { context.strokePath() }
            else if fill != nil { context.fillPath() }
        }
    }
}
private func render(_ variant: String, size: Int) -> CGImage {
    let space = CGColorSpaceCreateDeviceRGB()
    guard let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { fail("cannot create bitmap") }
    context.scaleBy(x: CGFloat(size)/1024, y: CGFloat(size)/1024)
    context.translateBy(x: 0, y: 1024); context.scaleBy(x: 1, y: -1)
    for layer in ["background", "route", "nodes"] { drawLayer(sources.appendingPathComponent("\(variant)/\(layer).svg"), in: context) }
    guard let image = context.makeImage() else { fail("cannot render image") }
    return image
}
private func writePNG(_ image: CGImage, to url: URL) {
    guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else { fail("cannot write \(url.path)") }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else { fail("PNG write failed") }
}
private func verifyPNG(_ url: URL, size: Int, height: Int? = nil) {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil), CGImageSourceGetType(source) as String? == UTType.png.identifier,
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
          image.width == size, image.height == (height ?? size), image.alphaInfo != .none, image.alphaInfo != .noneSkipLast,
          image.alphaInfo != .noneSkipFirst else { fail("invalid PNG size or alpha: \(url.path)") }
}
private func makeContents() -> Data {
    let rows: [[String: String]] = points.flatMap { pt in [1, 2].map { scale in
        ["filename": "AppIcon-\(pt)@\(scale)x.png", "idiom": "mac", "size": "\(pt)x\(pt)", "scale": "\(scale)x"]
    } }
    return try! JSONSerialization.data(withJSONObject: ["images": rows, "info": ["author": "xcode", "version": 1]], options: [.prettyPrinted, .sortedKeys])
}
private func makeContactSheet() {
    let width = 1900, height = 2800
    let space = CGColorSpaceCreateDeviceRGB()
    guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { fail("cannot create sheet") }
    context.setFillColor(color("#808C94")); context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    for (row, variant) in variants.enumerated() {
        for (side, background) in ["#F1F5F7", "#132632"].enumerated() {
            let left = CGFloat(side * 950)
            let bottom = CGFloat(height - (row + 1) * 560)
            context.setFillColor(color(background))
            context.fill(CGRect(x: left + 8, y: bottom + 8, width: 934, height: 544))
            let label = "\(variant) · \(side == 0 ? "light" : "dark") · 16  32  64  128  512 px"
            let font = CTFontCreateWithName("HelveticaNeue" as CFString, 18, nil)
            let labelColor = color(side == 0 ? "#102D38" : "#F6FFFD")
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: label, attributes: [
                NSAttributedString.Key(kCTFontAttributeName as String): font,
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): labelColor
            ]))
            context.textPosition = CGPoint(x: left + 26, y: bottom + 516)
            CTLineDraw(line, context)
            let sizes = [16, 32, 64, 128, 512]
            let xPositions: [CGFloat] = [48, 110, 190, 280, 420]
            for (index, size) in sizes.enumerated() {
                let image = render(variant, size: size)
                let iconSize = CGFloat(size)
                let frame = CGRect(x: left + xPositions[index], y: bottom + (544-iconSize)/2,
                                   width: iconSize, height: iconSize)
                context.draw(image, in: frame)
            }
        }
    }
    guard let image = context.makeImage() else { fail("cannot create sheet image") }
    let url = generated.appendingPathComponent("ContactSheet.png")
    writePNG(image, to: url); verifyPNG(url, size: width, height: height)
}
private func run() throws {
    let fm = FileManager.default
    try fm.createDirectory(at: generated, withIntermediateDirectories: true)
    try fm.createDirectory(at: appIcon, withIntermediateDirectories: true)
    let marker = ".generated-by-netunstick-icon-generator"
    let manifestName = ".generated-checksums.json"
    let owned = Set(points.flatMap { pt in [1,2].map { "AppIcon-\(pt)@\($0)x.png" } } + ["Contents.json", marker, manifestName])
    let existing = try fm.contentsOfDirectory(atPath: appIcon.path)
    let unexpected = existing.filter { !owned.contains($0) && $0 != ".DS_Store" }
    guard unexpected.isEmpty else { fail("manual files in appiconset; move them before generating: \(unexpected.joined(separator: ", "))") }
    guard existing.isEmpty || existing.contains(marker) else { fail("appiconset has no generator ownership marker; refusing overwrite") }
    let checksumURL = appIcon.appendingPathComponent(manifestName)
    var outputURLs = points.flatMap { pt in [1,2].map { appIcon.appendingPathComponent("AppIcon-\(pt)@\($0)x.png") } }
    outputURLs.append(appIcon.appendingPathComponent("Contents.json"))
    for variant in variants { for size in [16,32,64,128,512,1024] {
        outputURLs.append(generated.appendingPathComponent("\(variant)/\(size).png"))
    } }
    outputURLs.append(generated.appendingPathComponent("ContactSheet.png"))
    func checksum(_ url: URL) throws -> String { SHA256.hash(data: try Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined() }
    if fm.fileExists(atPath: checksumURL.path) {
        let saved = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: checksumURL))
        guard saved.count == outputURLs.count else { fail("checksum manifest is incomplete") }
        for url in outputURLs {
            let key = url.path.replacingOccurrences(of: root.path + "/", with: "")
            guard let expected = saved[key], fm.fileExists(atPath: url.path), try checksum(url) == expected else {
                fail("generated file was edited or removed; refusing overwrite: \(key)")
            }
        }
    } else if outputURLs.contains(where: { fm.fileExists(atPath: $0.path) }) {
        fail("generated output exists without checksum manifest; refusing overwrite")
    }
    for variant in variants {
        let dir = generated.appendingPathComponent(variant)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        for size in [16, 32, 64, 128, 512, 1024] {
            let url = dir.appendingPathComponent("\(size).png")
            writePNG(render(variant, size: size), to: url); verifyPNG(url, size: size)
        }
    }
    for pt in points { for scale in [1,2] {
        let size = pt * scale
        let url = appIcon.appendingPathComponent("AppIcon-\(pt)@\(scale)x.png")
        writePNG(render("Default", size: size), to: url); verifyPNG(url, size: size)
    } }
    try makeContents().write(to: appIcon.appendingPathComponent("Contents.json"), options: .atomic)
    try "Generated by Tools/AppIconGenerator/main.swift\n".write(to: appIcon.appendingPathComponent(marker), atomically: true, encoding: .utf8)
    makeContactSheet()
    var hashes: [String: String] = [:]
    for url in outputURLs { hashes[url.path.replacingOccurrences(of: root.path + "/", with: "")] = try checksum(url) }
    let checksumData = try JSONSerialization.data(withJSONObject: hashes, options: [.prettyPrinted, .sortedKeys])
    try checksumData.write(to: checksumURL, options: .atomic)
    print("Generated 10 macOS slots and 5 variant sets")
}
do { try run() } catch { fail("\(error)") }
