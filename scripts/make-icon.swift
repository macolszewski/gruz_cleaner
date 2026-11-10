// Renders Resources/AppIcon.svg as a square PNG.
// Usage: swift scripts/make-icon.swift <input.svg> <output.png> <pixels>
// scripts/make-icns.sh calls it once per iconset size, so every size is drawn from the vector source.
import AppKit

let args = CommandLine.arguments
guard args.count == 4, let px = Int(args[3]), px > 0 else {
    FileHandle.standardError.write("usage: make-icon.swift <input.svg> <output.png> <pixels>\n".data(using: .utf8)!)
    exit(2)
}
guard let image = NSImage(contentsOf: URL(fileURLWithPath: args[1])) else {
    FileHandle.standardError.write("cannot read \(args[1])\n".data(using: .utf8)!)
    exit(1)
}

let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
    samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
NSGraphicsContext.current?.imageInterpolation = .high
image.draw(in: NSRect(x: 0, y: 0, width: px, height: px))
NSGraphicsContext.restoreGraphicsState()

try rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: args[2]))
