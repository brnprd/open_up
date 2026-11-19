// Draws the OPEN_UP icon (white ">_" on black) into an .iconset folder.
import Cocoa

let out = CommandLine.arguments[1]
try? FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)

for (size, scale) in [(16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2), (256, 1), (256, 2), (512, 1), (512, 2)] {
    let px = size * scale
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = CGFloat(px)
    let inset = s * 0.09
    let rect = NSRect(x: inset, y: inset, width: s - inset * 2, height: s - inset * 2)
    NSColor.black.setFill()
    NSBezierPath(roundedRect: rect, xRadius: s * 0.08, yRadius: s * 0.08).fill()
    NSColor.white.setStroke()
    let border = NSBezierPath(roundedRect: rect.insetBy(dx: s * 0.04, dy: s * 0.04), xRadius: s * 0.03, yRadius: s * 0.03)
    border.lineWidth = max(1, s * 0.025)
    border.stroke()
    let font = NSFont.monospacedSystemFont(ofSize: s * 0.36, weight: .bold)
    let text = NSAttributedString(string: ">_", attributes: [.font: font, .foregroundColor: NSColor.white])
    let ts = text.size()
    text.draw(at: NSPoint(x: (s - ts.width) / 2, y: (s - ts.height) / 2))
    NSGraphicsContext.restoreGraphicsState()
    let name = scale == 1 ? "icon_\(size)x\(size).png" : "icon_\(size)x\(size)@2x.png"
    try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "\(out)/\(name)"))
}
