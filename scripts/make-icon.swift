import AppKit

// Package the approved logo unchanged inside the standard macOS rounded tile.
// Usage: make-icon <source.png> <output.png>
guard CommandLine.arguments.count == 3,
      let logo = NSImage(contentsOfFile: CommandLine.arguments[1]) else {
    fputs("Usage: make-icon <source.png> <output.png>\n", stderr)
    exit(1)
}
let size = 1024
let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
let context = NSGraphicsContext(bitmapImageRep: bitmap)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = context
NSColor.clear.setFill()
NSRect(x: 0, y: 0, width: size, height: size).fill()
let tile = NSRect(x: 62, y: 62, width: 900, height: 900)
NSBezierPath(roundedRect: tile, xRadius: 204, yRadius: 204).addClip()
NSColor.white.setFill()
tile.fill()
context.imageInterpolation = .high
logo.draw(in: tile, from: .zero, operation: .sourceOver, fraction: 1)
NSGraphicsContext.restoreGraphicsState()
try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[2]))
