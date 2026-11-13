import Accelerate
import Foundation

/// A song's waveform for drawing (min/max per bucket) and its onset strength for snapping taps.
public struct Waveform: Sendable {
    public let duration: Double
    /// Peaks per second of `mins`/`maxs`.
    public let rate: Double
    public let mins: [Float]
    public let maxs: [Float]
    /// Onset strength (spectral flux) and its frames per second, for snapping.
    public let onset: [Float]
    public let onsetRate: Double
    let onsetOffset: Double

    public static func load(_ url: URL, peaksPerSecond: Double = 400) throws -> Waveform {
        let (samples, sr) = try BeatDetector.readMono(url)
        return Waveform(samples: samples, sampleRate: sr, peaksPerSecond: peaksPerSecond)
    }

    public init(samples: [Float], sampleRate: Double, peaksPerSecond: Double = 400) {
        duration = Double(samples.count) / sampleRate
        let size = max(1, Int(sampleRate / peaksPerSecond))
        let n = samples.count / size
        rate = sampleRate / Double(size)
        var lo = [Float](repeating: 0, count: n), hi = [Float](repeating: 0, count: n)
        samples.withUnsafeBufferPointer { p in
            for i in 0..<n {
                let s = UnsafeBufferPointer(rebasing: p[(i * size)..<((i + 1) * size)])
                lo[i] = vDSP.minimum(s)
                hi[i] = vDSP.maximum(s)
            }
        }
        mins = lo
        maxs = hi
        onset = BeatDetector.onsetEnvelope(samples: samples)
        onsetRate = sampleRate / Double(BeatDetector.hop)
        onsetOffset = Double(BeatDetector.frameSize / 2) / sampleRate
    }

    /// The strongest attack within `window` seconds of `time` (taps land a little early or late).
    public func snapToAttack(_ time: Double, window: Double = 0.08) -> Double {
        guard !onset.isEmpty else { return time }
        let c = Int(((time - onsetOffset) * onsetRate).rounded())
        let r = Int((window * onsetRate).rounded())
        let a = max(0, c - r), b = min(onset.count - 1, c + r)
        guard a <= b else { return time }
        var best = a
        for i in a...b where onset[i] > onset[best] { best = i }
        return onset[best] > 0.5 ? Double(best) / onsetRate + onsetOffset : time
    }

    /// Min/max of the peaks covering [t0, t1), for one pixel column.
    public func range(from t0: Double, to t1: Double) -> (Float, Float) {
        let a = max(0, Int(t0 * rate)), b = min(maxs.count, max(a + 1, Int(t1 * rate)))
        guard a < b else { return (0, 0) }
        return mins.withUnsafeBufferPointer { lp in
            maxs.withUnsafeBufferPointer { hp in
                (vDSP.minimum(UnsafeBufferPointer(rebasing: lp[a..<b])), vDSP.maximum(UnsafeBufferPointer(rebasing: hp[a..<b])))
            }
        }
    }
}
