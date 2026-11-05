// Renders the placeholder app icon (1024 px): a dark rounded square with a window and a small "second screen".
import AppKit
let size = 1024.0
let img = NSImage(size: NSSize(width: size, height: size))
img.lockFocus()
let ctx = NSGraphicsContext.current!.cgContext
let inset = size * 0.1
let rect = CGRect(x: inset, y: inset, width: size - 2 * inset, height: size - 2 * inset)
let path = CGPath(roundedRect: rect, cornerWidth: size * 0.18, cornerHeight: size * 0.18, transform: nil)
ctx.addPath(path); ctx.clip()
let colors = [NSColor(calibratedRed: 0.13, green: 0.16, blue: 0.24, alpha: 1).cgColor,
              NSColor(calibratedRed: 0.27, green: 0.33, blue: 0.55, alpha: 1).cgColor] as CFArray
let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1])!
ctx.drawLinearGradient(g, start: CGPoint(x: 0, y: 0), end: CGPoint(x: size, y: size), options: [])
func window(_ r: CGRect, _ alpha: CGFloat) {
    let p = CGPath(roundedRect: r, cornerWidth: 36, cornerHeight: 36, transform: nil)
    ctx.setFillColor(NSColor(white: 1, alpha: alpha).cgColor); ctx.addPath(p); ctx.fillPath()
    ctx.setFillColor(NSColor(white: 0, alpha: 0.18).cgColor)
    ctx.fill(CGRect(x: r.minX, y: r.maxY - 70, width: r.width, height: 70))
    for (i, c) in [NSColor.systemRed, .systemYellow, .systemGreen].enumerated() {
        ctx.setFillColor(c.cgColor)
        ctx.fillEllipse(in: CGRect(x: r.minX + 30 + CGFloat(i) * 46, y: r.maxY - 52, width: 32, height: 32))
    }
}
window(CGRect(x: 230, y: 300, width: 470, height: 360), 0.35)
window(CGRect(x: 330, y: 230, width: 470, height: 360), 0.92)
img.unlockFocus()
let rep = NSBitmapImageRep(data: img.tiffRepresentation!)!
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
