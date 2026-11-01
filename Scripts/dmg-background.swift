// Draws the DMG window background (app on the left, Applications on the right, arrow between).
// Usage: swift dmg-background.swift <out.png> <scale>   (scale 1 → 600x400, scale 2 → @2x)
import AppKit

let args = CommandLine.arguments
let out = URL(fileURLWithPath: args[1])
let scale = CGFloat(Double(args[2]) ?? 1)
let size = NSSize(width: 600 * scale, height: 400 * scale)

let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width), pixelsHigh: Int(size.height),
                           bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                           colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let ctx = NSGraphicsContext.current!.cgContext
ctx.scaleBy(x: scale, y: scale)

// Background gradient (AppKit coordinates: origin bottom-left).
NSGradient(starting: NSColor(calibratedRed: 0.98, green: 0.98, blue: 1.0, alpha: 1),
           ending: NSColor(calibratedRed: 0.88, green: 0.91, blue: 0.96, alpha: 1))!
    .draw(in: NSRect(x: 0, y: 0, width: 600, height: 400), angle: -90)

// Dashed arrow from the app slot (x=150) to the Applications slot (x=450), at icon height (y=200 from top).
NSColor(calibratedRed: 0.2, green: 0.45, blue: 0.95, alpha: 0.8).setStroke()
let arrow = NSBezierPath()
arrow.move(to: NSPoint(x: 235, y: 200))
arrow.line(to: NSPoint(x: 355, y: 200))
arrow.lineWidth = 4
arrow.lineCapStyle = .round
arrow.setLineDash([10, 8], count: 2, phase: 0)
arrow.stroke()
let head = NSBezierPath()
head.move(to: NSPoint(x: 350, y: 214))
head.line(to: NSPoint(x: 368, y: 200))
head.line(to: NSPoint(x: 350, y: 186))
head.lineWidth = 4
head.lineCapStyle = .round
head.lineJoinStyle = .round
head.stroke()

func text(_ s: String, y: CGFloat, size: CGFloat, weight: NSFont.Weight, alpha: CGFloat) {
    let p = NSMutableParagraphStyle()
    p.alignment = .center
    NSAttributedString(string: s, attributes: [
        .font: NSFont.systemFont(ofSize: size, weight: weight),
        .foregroundColor: NSColor(white: 0.1, alpha: alpha),
        .paragraphStyle: p,
    ]).draw(in: NSRect(x: 0, y: y, width: 600, height: size * 1.4))
}
text("Video Converter", y: 330, size: 26, weight: .semibold, alpha: 0.9)
text("Drag the app onto Applications to install", y: 60, size: 14, weight: .regular, alpha: 0.6)

NSGraphicsContext.current = nil
try! rep.representation(using: .png, properties: [:])!.write(to: out)
