import Foundation
import FCPXMLKit

/// How a clip sits in the 9:16 frame: a tilt, zoom on top of the auto-crop, and the offset of its centre from
/// the frame's centre, in output pixels (x right, y down, as on screen).
///
/// `angle` straightens a clip shot a degree or two off: degrees, counter-clockwise positive (as in Final Cut).
/// The auto-crop scales the tilted clip up just enough to cover the frame again, so no corner ever shows;
/// zoom 1 is that size (with no tilt, Final Cut's "fill"). Offsets are clamped so the clip always covers the frame.
public struct Reframe: Equatable, Sendable, Codable {
    public var zoom: Double
    public var dx: Double
    public var dy: Double
    public var angle: Double
    /// A slow zoom over the cut, in percent: +3 pushes in from this framing to 3 % closer by the cut's end,
    /// -3 starts 3 % closer and pulls out to this framing. Never below the framing, so the frame stays covered.
    public var push: Double

    public init(zoom: Double = 1, dx: Double = 0, dy: Double = 0, angle: Double = 0, push: Double = 0) {
        self.zoom = zoom
        self.dx = dx
        self.dy = dy
        self.angle = angle
        self.push = push
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        zoom = try c.decode(Double.self, forKey: .zoom)
        dx = try c.decode(Double.self, forKey: .dx)
        dy = try c.decode(Double.self, forKey: .dy)
        angle = try c.decodeIfPresent(Double.self, forKey: .angle) ?? 0
        push = try c.decodeIfPresent(Double.self, forKey: .push) ?? 0
    }

    public static let centred = Reframe()
    public static let maxZoom = 3.0
    public static let maxAngle = 10.0
    public static let maxPush = 10.0

    /// Scale over the framing at `progress` (0 = the cut's first frame, 1 = its end).
    public func pushScale(at progress: Double) -> Double {
        let p = min(max(progress, 0), 1), k = abs(push) / 100
        return 1 + k * (push >= 0 ? p : 1 - p)
    }

    /// Scale that makes a `w`×`h` clip just cover the `frameW`×`frameH` frame (Final Cut's "fill").
    public static func fillScale(w: Double, h: Double, frameW: Double, frameH: Double) -> Double {
        max(frameW / w, frameH / h)
    }

    /// Half the frame's extent along the tilted clip's own axes (the frame's corners seen from the clip).
    func frameExtent(frameW: Double, frameH: Double) -> (Double, Double) {
        let a = angle * .pi / 180, c = abs(cos(a)), s = abs(sin(a))
        return ((frameW * c + frameH * s) / 2, (frameW * s + frameH * c) / 2)
    }

    /// The auto-crop: how much more than "fill" the tilted clip must be scaled to cover the frame.
    public func cropScale(w: Double, h: Double, frameW: Double = 1080, frameH: Double = 1920) -> Double {
        let f = Reframe.fillScale(w: w, h: h, frameW: frameW, frameH: frameH)
        let (ex, ey) = frameExtent(frameW: frameW, frameH: frameH)
        return max(1, 2 * ex / (w * f), 2 * ey / (h * f))
    }

    /// Size of the (untilted) clip on the output frame, in output pixels.
    public func renderedSize(w: Double, h: Double, frameW: Double = 1080, frameH: Double = 1920) -> (Double, Double) {
        let f = Reframe.fillScale(w: w, h: h, frameW: frameW, frameH: frameH) * cropScale(w: w, h: h, frameW: frameW, frameH: frameH) * zoom
        return (w * f, h * f)
    }

    /// Angle within ±maxAngle, zoom within [1, maxZoom] and offsets within what keeps the frame covered.
    public func clamped(w: Double, h: Double, frameW: Double = 1080, frameH: Double = 1920) -> Reframe {
        var r = self
        r.angle = min(max(angle, -Reframe.maxAngle), Reframe.maxAngle)
        r.zoom = min(max(zoom, 1), Reframe.maxZoom)
        r.push = min(max(push, -Reframe.maxPush), Reframe.maxPush)
        let (rw, rh) = r.renderedSize(w: w, h: h, frameW: frameW, frameH: frameH)
        let (ex, ey) = r.frameExtent(frameW: frameW, frameH: frameH)
        let mx = max(0, rw / 2 - ex), my = max(0, rh / 2 - ey)
        // The offset along the clip's own axes (y down, the clip turned counter-clockwise by `angle`).
        let a = r.angle * .pi / 180, c = cos(a), s = sin(a)
        let u = min(max(dx * c - dy * s, -mx), mx)
        let v = min(max(dx * s + dy * c, -my), my)
        r.dx = u * c + v * s
        r.dy = -u * s + v * c
        return r
    }

    /// Final Cut's transform for a `w`×`h` clip conformed with "fill": scale on top of fill (the auto-crop
    /// times zoom), position in percent of the frame height with y up, rotation in degrees counter-clockwise;
    /// with a push, the scale at the first frame and at the end.
    public func fcpTransform(w: Double, h: Double, frameW: Double = 1080, frameH: Double = 1920) -> FCPTransform {
        let s = cropScale(w: w, h: h, frameW: frameW, frameH: frameH) * zoom
        return FCPTransform(positionX: dx / frameH * 100, positionY: -dy / frameH * 100,
                            scale: s * pushScale(at: 0), rotation: angle, scaleEnd: push == 0 ? nil : s * pushScale(at: 1))
    }
}
