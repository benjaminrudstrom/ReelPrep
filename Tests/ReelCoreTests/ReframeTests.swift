import CoreGraphics
import Testing
import FCPXMLKit
@testable import ReelCore

@Suite struct ReframeTests {
    @Test func landscapeFillsByHeightAndPansSideways() {
        // 3840×2160 drone shot in 1080×1920: fill scale 1920/2160, width 3413 px, overhang 1166 px each side.
        let r = Reframe(zoom: 1, dx: 5000, dy: 300).clamped(w: 3840, h: 2160)
        #expect(abs(r.dx - (3840 * 1920 / 2160 - 1080) / 2) < 1e-6)
        #expect(r.dy == 0)
    }

    @Test func portraitOnlyPansWhenZoomed() {
        #expect(Reframe(zoom: 1, dx: 50, dy: 50).clamped(w: 2160, h: 3840) == .centred)
        let z = Reframe(zoom: 2, dx: 9999, dy: -9999).clamped(w: 2160, h: 3840)
        #expect(z.dx == 540 && z.dy == -960)
        #expect(Reframe(zoom: 9).clamped(w: 2160, h: 3840).zoom == Reframe.maxZoom)
    }

    @Test func finalCutUnitsArePercentOfHeightYUp() {
        let t = Reframe(zoom: 1.5, dx: 192, dy: 96).fcpTransform(w: 2160, h: 3840)
        #expect(t.positionX == 10 && t.positionY == -5 && t.scale == 1.5 && t.rotation == 0)
    }

    /// The auto-crop: a tilted clip, however it is panned, still covers every point of the frame's edge.
    /// Checked with the same transform the preview draws (turn the clip about its centre, then move it).
    @Test func tiltedClipAlwaysCoversTheFrame() {
        for (w, h) in [(2160.0, 3840.0), (3840.0, 2160.0), (1080.0, 1920.0)] {
            for angle in [-10.0, -2.3, 0.7, 1.5, 6] {
                for (dx, dy, zoom) in [(0.0, 0.0, 1.0), (5000, 0, 1), (-3000, 4000, 1), (900, -900, 1.4)] {
                    let r = Reframe(zoom: zoom, dx: dx, dy: dy, angle: angle).clamped(w: w, h: h)
                    let (rw, rh) = r.renderedSize(w: w, h: h)
                    // Clip → screen (y down): a counter-clockwise turn on screen, then the offset.
                    let a = r.angle * .pi / 180
                    let toScreen = CGAffineTransform(rotationAngle: -a).concatenating(CGAffineTransform(translationX: r.dx, y: r.dy))
                    let toClip = toScreen.inverted()
                    for i in 0...40 {
                        let t = Double(i) / 40
                        for p in [CGPoint(x: -540 + 1080 * t, y: -960), CGPoint(x: -540 + 1080 * t, y: 960),
                                  CGPoint(x: -540, y: -960 + 1920 * t), CGPoint(x: 540, y: -960 + 1920 * t)] {
                            let q = p.applying(toClip)
                            #expect(abs(q.x) <= rw / 2 + 1e-6 && abs(q.y) <= rh / 2 + 1e-6, "\(w)x\(h) \(angle)° \(dx),\(dy)")
                        }
                    }
                }
            }
        }
    }

    @Test func tiltCropsJustEnoughAndReachesFinalCut() {
        // Portrait clip, 2° off: about +6 %, set by the width ((1080·cos2° + 1920·sin2°) / 1080).
        let r = Reframe(angle: 2)
        let s = r.cropScale(w: 2160, h: 3840)
        let a = 2 * Double.pi / 180
        #expect(abs(s - max((1080 * cos(a) + 1920 * sin(a)) / 1080, (1080 * sin(a) + 1920 * cos(a)) / 1920)) < 1e-9)
        let t = r.fcpTransform(w: 2160, h: 3840)
        #expect(t.rotation == 2 && abs(t.scale - s) < 1e-12)
        #expect(Reframe(angle: 25).clamped(w: 2160, h: 3840).angle == Reframe.maxAngle)
        // A landscape drone shot keeps room to pan sideways when slightly tilted.
        #expect(Reframe(dx: 5000, angle: 1).clamped(w: 3840, h: 2160).dx > 1000)
    }

    @Test func pushZoomsFromTheFramingAndBack() {
        let inward = Reframe(zoom: 1.2, push: 3).fcpTransform(w: 2160, h: 3840)
        #expect(abs(inward.scale - 1.2) < 1e-12 && abs(inward.scaleEnd! - 1.236) < 1e-12)
        let outward = Reframe(zoom: 1.2, push: -3).fcpTransform(w: 2160, h: 3840)
        #expect(abs(outward.scale - 1.236) < 1e-12 && abs(outward.scaleEnd! - 1.2) < 1e-12)
        #expect(Reframe(zoom: 1.2).fcpTransform(w: 2160, h: 3840).scaleEnd == nil)
        #expect(Reframe(push: 40).clamped(w: 2160, h: 3840).push == Reframe.maxPush)
        #expect(Reframe(push: 4).pushScale(at: 0.5) == 1.02)
    }
}
