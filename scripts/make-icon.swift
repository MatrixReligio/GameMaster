// Renders the GameMaster app icon (1024pt master PNG).
// Usage: swift scripts/make-icon.swift <output.png>
import AppKit

let size: CGFloat = 1024
let output = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon_1024.png"

let image = NSImage(size: NSSize(width: size, height: size))
image.lockFocus()

// macOS icon grid: rounded-rect plate inset ~10% with ~22.5% corner radius.
let inset = size * 0.1
let plate = NSBezierPath(
    roundedRect: NSRect(x: inset, y: inset, width: size - 2 * inset, height: size - 2 * inset),
    xRadius: size * 0.185,
    yRadius: size * 0.185
)
let gradient = NSGradient(colors: [
    NSColor(calibratedRed: 0.28, green: 0.16, blue: 0.65, alpha: 1),
    NSColor(calibratedRed: 0.62, green: 0.26, blue: 0.94, alpha: 1)
])
gradient?.draw(in: plate, angle: 90)

// Subtle inner highlight.
NSColor.white.withAlphaComponent(0.12).setStroke()
plate.lineWidth = size * 0.008
plate.stroke()

/// Game controller symbol, white, centered.
let config = NSImage.SymbolConfiguration(pointSize: size * 0.42, weight: .medium)
if let symbol = NSImage(systemSymbolName: "gamecontroller.fill", accessibilityDescription: nil)?
    .withSymbolConfiguration(config) {
    let tinted = NSImage(size: symbol.size)
    tinted.lockFocus()
    NSColor.white.set()
    let rect = NSRect(origin: .zero, size: symbol.size)
    symbol.draw(in: rect)
    rect.fill(using: .sourceAtop)
    tinted.unlockFocus()

    let symbolSize = tinted.size
    let scale = (size * 0.52) / max(symbolSize.width, symbolSize.height)
    let drawSize = NSSize(width: symbolSize.width * scale, height: symbolSize.height * scale)
    tinted.draw(in: NSRect(
        x: (size - drawSize.width) / 2,
        y: (size - drawSize.height) / 2,
        width: drawSize.width,
        height: drawSize.height
    ))
}

image.unlockFocus()

guard
    let tiff = image.tiffRepresentation,
    let rep = NSBitmapImageRep(data: tiff),
    let png = rep.representation(using: .png, properties: [:])
else {
    fatalError("could not render icon")
}

try png.write(to: URL(fileURLWithPath: output))
print("wrote \(output)")
