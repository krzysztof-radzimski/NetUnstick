import Foundation
import CoreGraphics
import CoreText
import ImageIO
import UniformTypeIdentifiers

// Renders the Finder background of the installer image at 1x and 2x (660 x 400 pt).
// Usage: DMGBackground <output-dir> <version>
// The layout matches Tools/BuildDMG.sh: app icon centred at (165, 175), Applications at (495, 175).

let arguments = CommandLine.arguments
guard arguments.count == 3 else { fputs("usage: DMGBackground <output-dir> <version>\n", stderr); exit(2) }
let output = URL(fileURLWithPath: arguments[1], isDirectory: true)
let version = arguments[2]
let width: CGFloat = 660
let height: CGFloat = 400

func fail(_ message: String) -> Never { fputs("DMGBackground: \(message)\n", stderr); exit(1) }

func color(_ hex: String, _ alpha: CGFloat = 1) -> CGColor {
    guard hex.count == 7, hex.first == "#", let rgb = UInt32(hex.dropFirst(), radix: 16) else { fail("invalid color \(hex)") }
    return CGColor(red: CGFloat((rgb >> 16) & 255) / 255, green: CGFloat((rgb >> 8) & 255) / 255,
                   blue: CGFloat(rgb & 255) / 255, alpha: alpha)
}

enum Alignment { case left, center, right }

/// Draws one line of text; `point` is the baseline origin in top-left design coordinates.
func draw(_ text: String, at point: CGPoint, size: CGFloat, font name: String, color fill: CGColor,
          alignment: Alignment, in context: CGContext) {
    let font = CTFontCreateWithName(name as CFString, size, nil)
    let attributed = NSAttributedString(string: text, attributes: [
        NSAttributedString.Key(kCTFontAttributeName as String): font,
        NSAttributedString.Key(kCTForegroundColorAttributeName as String): fill
    ])
    let line = CTLineCreateWithAttributedString(attributed)
    let textWidth = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
    var x = point.x
    switch alignment {
    case .left: break
    case .center: x -= textWidth / 2
    case .right: x -= textWidth
    }
    context.textPosition = CGPoint(x: x, y: height - point.y)
    CTLineDraw(line, context)
}

func render(scale: CGFloat) -> CGImage {
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    guard let context = CGContext(data: nil, width: Int(width * scale), height: Int(height * scale),
                                  bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { fail("no context") }
    context.scaleBy(x: scale, y: scale)
    context.setAllowsAntialiasing(true)
    context.setShouldSmoothFonts(true)

    // Soft vertical gradient; the picture is static, so it must read well in light and dark Finder.
    let gradient = CGGradient(colorsSpace: space, colors: [color("#FBFCFD"), color("#E4E9F0")] as CFArray, locations: [0, 1])!
    context.drawLinearGradient(gradient, start: CGPoint(x: 0, y: height), end: CGPoint(x: 0, y: 0), options: [])

    // Slots behind the two icons.
    func slot(centerX: CGFloat, centerY: CGFloat, radius: CGFloat, fill: CGColor) {
        context.setFillColor(fill)
        context.fillEllipse(in: CGRect(x: centerX - radius, y: height - centerY - radius, width: radius * 2, height: radius * 2))
    }
    slot(centerX: 165, centerY: 175, radius: 98, fill: color("#3B82F6", 0.10))
    slot(centerX: 495, centerY: 175, radius: 98, fill: color("#64748B", 0.09))

    // Arrow from the app to the Applications shortcut.
    let arrowY = height - 175
    context.setStrokeColor(color("#8E8E93"))
    context.setLineWidth(4)
    context.setLineCap(.round)
    context.setLineJoin(.round)
    context.move(to: CGPoint(x: 268, y: arrowY))
    context.addLine(to: CGPoint(x: 392, y: arrowY))
    context.strokePath()
    context.move(to: CGPoint(x: 374, y: arrowY + 15))
    context.addLine(to: CGPoint(x: 392, y: arrowY))
    context.addLine(to: CGPoint(x: 374, y: arrowY - 15))
    context.strokePath()

    draw("NetUnstick", at: CGPoint(x: 40, y: 54), size: 26, font: "HelveticaNeue-Bold",
         color: color("#1D1D1F"), alignment: .left, in: context)
    draw("Diagnostyka i naprawa sieci lokalnej po rozłączeniu VPN", at: CGPoint(x: 40, y: 76), size: 13,
         font: "HelveticaNeue", color: color("#6E6E73"), alignment: .left, in: context)
    draw("Przeciągnij NetUnstick do folderu Aplikacje", at: CGPoint(x: 330, y: 326), size: 15,
         font: "HelveticaNeue-Medium", color: color("#3A3A3C"), alignment: .center, in: context)
    draw("Przy pierwszym uruchomieniu zatwierdź pomocnika w Elementach logowania, gdy aplikacja o to poprosi.",
         at: CGPoint(x: 330, y: 348), size: 11.5, font: "HelveticaNeue", color: color("#6E6E73"), alignment: .center, in: context)
    draw("Wersja \(version) · podpis lokalny „NetUnstick Local Code Signing”", at: CGPoint(x: 620, y: 384),
         size: 11, font: "HelveticaNeue", color: color("#98989D"), alignment: .right, in: context)

    guard let image = context.makeImage() else { fail("no image") }
    return image
}

func writePNG(_ image: CGImage, to url: URL) {
    guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
        fail("cannot write \(url.path)")
    }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else { fail("PNG write failed") }
}

writePNG(render(scale: 1), to: output.appendingPathComponent("background.png"))
writePNG(render(scale: 2), to: output.appendingPathComponent("background@2x.png"))
print("DMGBackground: rendered 660x400 pt at 1x and 2x")
