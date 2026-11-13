// Draws ReelPrep's app icon ("Frames on the beat" on orange) at 1024 px: assets/AppIcon.png.
// scripts/make_icon.sh turns it into assets/AppIcon.icns.
import AppKit

let size = 1024.0
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size), bitsPerSample: 8,
                           samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                           bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let ctx = NSGraphicsContext.current!.cgContext
// Flip so y grows downward, like the sketch.
ctx.translateBy(x: 0, y: size)
ctx.scaleBy(x: 1, y: -1)

func color(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(red: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255,
            blue: CGFloat(hex & 0xff) / 255, alpha: a)
}
func round(_ r: CGRect, _ radius: CGFloat, _ c: CGColor) {
    ctx.addPath(CGPath(roundedRect: r, cornerWidth: radius, cornerHeight: radius, transform: nil))
    ctx.setFillColor(c)
    ctx.fillPath()
}

// macOS icon grid: an 824 px rounded square centred on the 1024 canvas.
let inset = 100.0, body = size - 2 * inset
round(CGRect(x: inset, y: inset, width: body, height: body), 185, color(0xff6a3d))

// Everything else scales from the 120 px sketch: 1 sketch unit = body / 120.
let u = body / 120
func R(_ x: Double, _ y: Double, _ w: Double, _ h: Double) -> CGRect {
    CGRect(x: inset + x * u, y: inset + y * u, width: w * u, height: h * u)
}
// Bigger and bolder than the first sketch, so it stays crisp at Dock sizes (2026-11-10).
// Three 9:16-ish frames, fading from white.
round(R(12, 14, 28, 50), 5 * u, color(0xffffff))
round(R(46, 14, 28, 50), 5 * u, color(0xffffff, 0.82))
round(R(80, 14, 28, 50), 5 * u, color(0xffffff, 0.64))
// Beat lines between them.
round(R(40.5, 7, 5, 64), 2.5 * u, color(0x1c1c1e))
round(R(74.5, 7, 5, 64), 2.5 * u, color(0x1c1c1e))
// The song: fewer, wider waveform bars.
let bars: [(Double, Double)] = [(13, 14), (27, 23), (41, 11), (55, 27), (69, 17), (83, 21), (97, 12)]
for (x, h) in bars { round(R(x, 106 - h, 9, h), 4.5 * u, color(0xffffff)) }

let out = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "assets/AppIcon.png")
try! rep.representation(using: .png, properties: [:])!.write(to: out)
print("Wrote \(out.path)")
