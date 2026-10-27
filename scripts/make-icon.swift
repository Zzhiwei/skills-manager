// Renders the 1024px ocean app icon PNG. Usage: swift scripts/make-icon.swift out.png
import AppKit

let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1024, pixelsHigh: 1024, bitsPerSample: 8,
                           samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                           bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

// macOS icon grid: 824pt rounded square centered on a 1024 canvas.
let tile = NSBezierPath(roundedRect: NSRect(x: 100, y: 100, width: 824, height: 824), xRadius: 185, yRadius: 185)
let shadow = NSShadow()
shadow.shadowColor = .black.withAlphaComponent(0.35)
shadow.shadowBlurRadius = 24
shadow.shadowOffset = NSSize(width: 0, height: -10)
NSGraphicsContext.saveGraphicsState()
shadow.set()
NSColor(red: 0.01, green: 0.09, blue: 0.17, alpha: 1).setFill()
tile.fill()
NSGraphicsContext.restoreGraphicsState()
NSGradient(colors: [NSColor(red: 0.31, green: 0.82, blue: 0.85, alpha: 1),
                    NSColor(red: 0.06, green: 0.49, blue: 0.55, alpha: 1),
                    NSColor(red: 0.02, green: 0.22, blue: 0.36, alpha: 1),
                    NSColor(red: 0.01, green: 0.09, blue: 0.17, alpha: 1)])!.draw(in: tile, angle: -90)

func symbol(_ name: String, size: CGFloat, color: NSColor, center: NSPoint) {
    let cfg = NSImage.SymbolConfiguration(pointSize: size, weight: .bold)
        .applying(NSImage.SymbolConfiguration(paletteColors: [color]))
    let img = NSImage(systemSymbolName: name, accessibilityDescription: nil)!.withSymbolConfiguration(cfg)!
    img.draw(in: NSRect(x: center.x - img.size.width / 2, y: center.y - img.size.height / 2,
                        width: img.size.width, height: img.size.height))
}
symbol("water.waves", size: 380, color: NSColor(red: 0.79, green: 0.95, blue: 0.93, alpha: 1), center: NSPoint(x: 512, y: 450))
symbol("sparkle", size: 150, color: .white, center: NSPoint(x: 700, y: 700))

try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
