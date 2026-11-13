// Makes the 1024 px app icon from a picture of the icon (assets/icon-source.jpg): finds the dark rounded
// square in it, crops to it and places it on the macOS icon grid (824 px, rounded), dropping the background.
import AppKit

let args = CommandLine.arguments
let src = NSImage(contentsOfFile: args[1])!.cgImage(forProposedRect: nil, context: nil, hints: nil)!
let w = src.width, h = src.height
let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                    space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
ctx.draw(src, in: CGRect(x: 0, y: 0, width: w, height: h))
let px = ctx.data!.bindMemory(to: UInt8.self, capacity: w * h * 4)

// The icon's navy body: blue noticeably above red, dark. The grey background has r ≈ g ≈ b.
func isBody(_ x: Int, _ y: Int) -> Bool {
    let i = (y * w + x) * 4
    let r = Int(px[i]), g = Int(px[i + 1]), b = Int(px[i + 2])
    return b - r >= 10 && b < 90
}
// Rows/columns where the body spans a good stretch (ignores stray pixels).
func span(_ count: Int, _ length: Int, _ hit: (Int, Int) -> Bool) -> (Int, Int) {
    var lo = count, hi = -1
    for a in 0..<count {
        var n = 0
        for b in stride(from: 0, to: length, by: 2) where hit(a, b) { n += 1 }
        if n > length / 10 { lo = min(lo, a); hi = max(hi, a) }
    }
    return (lo, hi)
}
let (x0, x1) = span(w, h) { x, y in isBody(x, y) }
let (y0, y1) = span(h, w) { y, x in isBody(x, y) }   // y in CG coordinates (from the bottom)
let side = Double(max(x1 - x0, y1 - y0))
print("icon found at x \(x0)–\(x1), y \(y0)–\(y1)")

let size = 1024.0, inset = 100.0, body = size - 2 * inset
let out = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1024, pixelsHigh: 1024, bitsPerSample: 8, samplesPerPixel: 4,
                           hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: out)
let o = NSGraphicsContext.current!.cgContext
o.interpolationQuality = .high
let shape = CGPath(roundedRect: CGRect(x: inset, y: inset, width: body, height: body), cornerWidth: 185, cornerHeight: 185, transform: nil)
o.addPath(shape)
o.clip()
// Scale the found square onto the body, trimming a hair of the edge (anti-aliased border, shadow).
let trim = side * 0.012
let crop = CGRect(x: Double(x0) + trim, y: Double(y0) + trim, width: side - 2 * trim, height: side - 2 * trim)
let scale = body / crop.width
o.draw(src, in: CGRect(x: inset - crop.minX * scale, y: inset - crop.minY * scale, width: Double(w) * scale, height: Double(h) * scale))
try! out.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: args[2]))
print("Wrote \(args[2])")
