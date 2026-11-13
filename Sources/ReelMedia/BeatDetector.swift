import Accelerate
import AVFoundation
import Foundation

public struct BeatAnalysis: Sendable {
    public var bpm: Double
    /// Beat times in song seconds.
    public var beats: [Double]
}

/// Onset detection (spectral flux, vDSP FFT), tempo from the onset envelope's autocorrelation,
/// and beat tracking by dynamic programming (Ellis 2007).
public enum BeatDetector {
    public static let frameSize = 2048
    public static let hop = 512

    public static func analyze(url: URL) throws -> BeatAnalysis {
        let (samples, rate) = try readMono(url)
        return analyze(samples: samples, sampleRate: rate)
    }

    public static func readMono(_ url: URL) throws -> ([Float], Double) {
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        let frames = AVAudioFrameCount(file.length)
        guard let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return ([], format.sampleRate) }
        try file.read(into: buf)
        let n = Int(buf.frameLength)
        let ch = Int(format.channelCount)
        var mono = [Float](repeating: 0, count: n)
        guard let data = buf.floatChannelData else { return (mono, format.sampleRate) }
        for c in 0..<ch {
            vDSP.add(mono, UnsafeBufferPointer(start: data[c], count: n), result: &mono)
        }
        if ch > 1 { vDSP.multiply(1 / Float(ch), mono, result: &mono) }
        return (mono, format.sampleRate)
    }

    public static func analyze(samples: [Float], sampleRate: Double, minBPM: Double = 60, maxBPM: Double = 200) -> BeatAnalysis {
        let env = onsetEnvelope(samples: samples)
        guard env.count > 8 else { return BeatAnalysis(bpm: 0, beats: []) }
        let envRate = sampleRate / Double(hop)
        let period = tempoPeriod(env, envRate: envRate, minBPM: minBPM, maxBPM: maxBPM)
        var frames = track(env, period: period)
        frames = extend(frames, loudness: frameLoudness(samples: samples, count: env.count))
        let offset = Double(frameSize / 2) / sampleRate   // flux frame i is centred at i*hop + N/2
        return BeatAnalysis(bpm: 60 * envRate / period, beats: frames.map { Double($0) / envRate + offset })
    }

    /// RMS per envelope frame.
    static func frameLoudness(samples: [Float], count: Int) -> [Float] {
        (0..<count).map { i in
            let a = i * hop, b = min(samples.count, a + frameSize)
            guard b > a else { return 0 }
            return samples.withUnsafeBufferPointer { vDSP.rootMeanSquare(UnsafeBufferPointer(rebasing: $0[a..<b])) }
        }
    }

    /// Continues the beat grid at the tracked tempo before the first and after the last tracked beat while
    /// there is still sound (above 2 % of the song's median loudness, about -34 dB): fade-ins and fade-outs
    /// have beats too weak to track but are still music to cut on.
    static func extend(_ beats: [Int], loudness: [Float]) -> [Int] {
        guard beats.count >= 2, !loudness.isEmpty else { return beats }
        let sorted = loudness.sorted()
        let floor = 0.02 * sorted[sorted.count / 2]
        func audible(_ t: Int) -> Bool { t >= 0 && t < loudness.count && loudness[t] >= floor }
        // Local tempo at each end: the mean interval of the last/first few tracked beats.
        let k = min(8, beats.count - 1)
        let tail = Double(beats[beats.count - 1] - beats[beats.count - 1 - k]) / Double(k)
        let head = Double(beats[k] - beats[0]) / Double(k)
        var out = beats
        var t = Double(beats.last!) + tail
        while audible(Int(t.rounded())) { out.append(Int(t.rounded())); t += tail }
        var front: [Int] = []
        t = Double(beats[0]) - head
        while audible(Int(t.rounded())) { front.append(Int(t.rounded())); t -= head }
        return front.reversed() + out
    }

    /// Spectral flux of log-compressed magnitudes, local-mean removed, normalised.
    public static func onsetEnvelope(samples: [Float]) -> [Float] {
        let n = frameSize
        let count = samples.count >= n ? (samples.count - n) / hop + 1 : 0
        guard count > 1 else { return [] }
        let log2n = vDSP_Length(log2(Double(n)))
        guard let setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else { return [] }
        defer { vDSP_destroy_fftsetup(setup) }
        let window = vDSP.window(ofType: Float.self, usingSequence: .hanningDenormalized, count: n, isHalfWindow: false)
        var prev = [Float](repeating: 0, count: n / 2)
        var flux = [Float](repeating: 0, count: count)
        var frame = [Float](repeating: 0, count: n)
        var re = [Float](repeating: 0, count: n / 2)
        var im = [Float](repeating: 0, count: n / 2)
        var mag = [Float](repeating: 0, count: n / 2)
        for i in 0..<count {
            samples.withUnsafeBufferPointer { p in
                vDSP.multiply(UnsafeBufferPointer(rebasing: p[(i * hop)..<(i * hop + n)]), window, result: &frame)
            }
            re.withUnsafeMutableBufferPointer { rp in
                im.withUnsafeMutableBufferPointer { ip in
                    var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                    frame.withUnsafeBufferPointer { fp in
                        fp.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: n / 2) {
                            vDSP_ctoz($0, 2, &split, 1, vDSP_Length(n / 2))
                        }
                    }
                    vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                    ip[0] = 0 // packed Nyquist; ignore
                    vDSP_zvabs(&split, 1, &mag, 1, vDSP_Length(n / 2))
                }
            }
            // log(1 + C * |X|)
            vDSP.multiply(Float(100), mag, result: &mag)
            vDSP.add(Float(1), mag, result: &mag)
            mag = vForce.log(mag)
            if i > 0 {
                var diff = vDSP.subtract(mag, prev)
                diff = vDSP.clip(diff, to: 0...Float.greatestFiniteMagnitude)
                flux[i] = vDSP.sum(diff)
            }
            swap(&prev, &mag)
            mag = [Float](repeating: 0, count: n / 2)
        }
        // Remove the local mean (~0.25 s each side), keep the positive part, normalise by std.
        let w = 20
        var out = [Float](repeating: 0, count: count)
        var prefix = [Float](repeating: 0, count: count + 1)
        for i in 0..<count { prefix[i + 1] = prefix[i] + flux[i] }
        for i in 0..<count {
            let a = max(0, i - w), b = min(count, i + w + 1)
            out[i] = max(0, flux[i] - (prefix[b] - prefix[a]) / Float(b - a))
        }
        let mean = vDSP.mean(out)
        let std = sqrt(vDSP.mean(vDSP.square(vDSP.add(-mean, out))))
        return std > 0 ? vDSP.divide(out, std) : out
    }

    /// Beat period in envelope frames: autocorrelation weighted towards 120 BPM (log-Gaussian, 1 octave).
    static func tempoPeriod(_ env: [Float], envRate: Double, minBPM: Double, maxBPM: Double) -> Double {
        let minLag = max(1, Int((60 * envRate / maxBPM).rounded(.down)))
        let maxLag = min(env.count - 2, Int((60 * envRate / minBPM).rounded(.up)))
        guard maxLag > minLag else { return 60 * envRate / 120 }
        var ac = [Double](repeating: 0, count: maxLag + 2)
        for lag in minLag...(maxLag + 1) where lag < env.count {
            var s: Float = 0
            env.withUnsafeBufferPointer { p in
                vDSP_dotpr(p.baseAddress!, 1, p.baseAddress! + lag, 1, &s, vDSP_Length(env.count - lag))
            }
            ac[lag] = Double(s) / Double(env.count - lag)
        }
        let center = 60 * envRate / 120
        var best = minLag
        var bestScore = -Double.infinity
        for lag in minLag...maxLag {
            let wgt = exp(-0.5 * pow(log2(Double(lag) / center), 2))
            let score = wgt * ac[lag]
            if score > bestScore { bestScore = score; best = lag }
        }
        // Parabolic refinement on the raw autocorrelation.
        if best > minLag && best < maxLag {
            let (a, b, c) = (ac[best - 1], ac[best], ac[best + 1])
            let d = a - 2 * b + c
            if d < 0 { return Double(best) + 0.5 * (a - c) / d }
        }
        return Double(best)
    }

    /// Dynamic-programming beat tracker; returns envelope frame indices.
    static func track(_ env: [Float], period: Double, tightness: Double = 1600) -> [Int] {
        let n = env.count
        // Local score: the envelope smoothed with a Gaussian about a beat wide (as in Ellis 2007 / librosa),
        // so single off-beat accents don't pull the phase.
        let half = Int(period.rounded())
        let kernel = (-half...half).map { exp(-0.5 * pow(Double($0) * 32 / period, 2)) }
        var local = [Double](repeating: 0, count: n)
        for t in 0..<n {
            var s = 0.0
            for (k, w) in kernel.enumerated() {
                let i = t + k - half
                if i >= 0 && i < n { s += w * Double(env[i]) }
            }
            local[t] = s
        }
        var score = local
        var back = [Int](repeating: -1, count: n)
        let lo = Int((period / 2).rounded(.down)), hi = Int((period * 2).rounded(.up))
        for t in 0..<n {
            var bestVal = -Double.infinity, bestPrev = -1
            let a = max(0, t - hi), b = t - max(1, lo)
            if b >= a {
                for p in a...b {
                    let r = log(Double(t - p) / period)
                    let v = score[p] - tightness * r * r
                    if v > bestVal { bestVal = v; bestPrev = p }
                }
            }
            if bestPrev >= 0 && bestVal > 0 {
                score[t] += bestVal
                back[t] = bestPrev
            }
        }
        // Start from the best-scoring frame within the last period that is a local maximum.
        let tailStart = max(0, n - Int(period.rounded(.up)))
        var end = tailStart
        for t in tailStart..<n where score[t] > score[end] { end = t }
        var beats: [Int] = []
        var t = end
        while t >= 0 { beats.append(t); t = back[t] }
        beats.reverse()
        // Drop leading/trailing beats on silence (onset well below the median strength).
        let strengths = beats.map { env[$0] }.sorted()
        let median = strengths.isEmpty ? 0 : strengths[strengths.count / 2]
        while let f = beats.first, env[f] < 0.2 * median, beats.count > 2 { beats.removeFirst() }
        while let l = beats.last, env[l] < 0.2 * median, beats.count > 2 { beats.removeLast() }
        return beats
    }
}
