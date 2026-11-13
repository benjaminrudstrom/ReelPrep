import AVFoundation
import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
import FCPXMLKit
import ReelCore
@testable import ReelMedia

/// Synthetic media made in a temp folder: clips, a click-track song and a logo.
enum TestMedia {
    static func folder() throws -> URL {
        let u = FileManager.default.temporaryDirectory.appendingPathComponent("reelprep-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }

    /// Click track: short noise bursts every 60/bpm seconds starting at `first`.
    static func clickSamples(bpm: Double, seconds: Double, rate: Double = 44100, first: Double = 0.25) -> [Float] {
        var s = [Float](repeating: 0, count: Int(seconds * rate))
        var gen = SystemRandomNumberGenerator()
        var t = first
        while t < seconds {
            let start = Int(t * rate)
            for i in 0..<Int(0.02 * rate) where start + i < s.count {
                let decay = Float(exp(-Double(i) / (0.004 * rate)))
                s[start + i] = Float.random(in: -0.8...0.8, using: &gen) * decay
            }
            t += 60 / bpm
        }
        // Quiet pad so it isn't pure silence between clicks.
        for i in s.indices { s[i] += 0.01 * sin(Float(i) * 2 * .pi * 220 / Float(rate)) }
        return s
    }

    static func writeWAV(_ samples: [Float], to url: URL, rate: Double = 44100) throws {
        let fmt = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2)!
        let file = try AVAudioFile(forWriting: url, settings: [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: rate,
                                                               AVNumberOfChannelsKey: 2, AVLinearPCMBitDepthKey: 16,
                                                               AVLinearPCMIsFloatKey: false])
        let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(samples.count))!
        buf.frameLength = AVAudioFrameCount(samples.count)
        for c in 0..<2 { samples.withUnsafeBufferPointer { buf.floatChannelData![c].update(from: $0.baseAddress!, count: samples.count) } }
        try file.write(from: buf)
    }

    static func writePNG(width: Int, height: Int, to url: URL) throws {
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: height / 4, width: width, height: height / 2))
        let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
        #expect(CGImageDestinationFinalize(dest))
    }

    /// A small H.264 .mov at `fps`, with a creation date.
    static func writeClip(to url: URL, width: Int, height: Int, fps: Int32, seconds: Double, created: String) async throws {
        let w = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264,
                                                                           AVVideoWidthKey: width, AVVideoHeightKey: height])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height])
        let date = AVMutableMetadataItem()
        date.identifier = .quickTimeMetadataCreationDate
        date.value = created as NSString
        w.metadata = [date]
        w.add(input)
        #expect(w.startWriting())
        w.startSession(atSourceTime: .zero)
        let frames = Int(seconds * Double(fps))
        for i in 0..<frames {
            while !input.isReadyForMoreMediaData { try await Task.sleep(nanoseconds: 1_000_000) }
            var pb: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &pb)
            CVPixelBufferLockBaseAddress(pb!, [])
            memset(CVPixelBufferGetBaseAddress(pb!), Int32(i * 3 % 255), CVPixelBufferGetDataSize(pb!))
            CVPixelBufferUnlockBaseAddress(pb!, [])
            adaptor.append(pb!, withPresentationTime: CMTime(value: CMTimeValue(i), timescale: fps))
        }
        input.markAsFinished()
        await w.finishWriting()
        #expect(w.status == .completed)
    }
}

@Suite struct BeatDetectorTests {
    @Test(arguments: [100.0, 120.0, 128.0])
    func findsTempoOfClickTrack(bpm: Double) {
        let samples = TestMedia.clickSamples(bpm: bpm, seconds: 20)
        let a = BeatDetector.analyze(samples: samples, sampleRate: 44100)
        #expect(abs(a.bpm - bpm) < 1.5, "bpm \(a.bpm)")
        let period = 60 / bpm
        // Beats line up with the clicks (within 30 ms, about one frame).
        let off = a.beats.map { b -> Double in
            let k = ((b - 0.25) / period).rounded()
            return abs(b - (0.25 + k * period))
        }
        #expect(off.max()! < 0.03, "max offset \(off.max()!)")
        #expect(Double(a.beats.count) > 20 / period - 3)
    }
}

@Suite struct BeatExtensionTests {
    @Test func beatsContinueThroughAFadeOut() {
        // 120 BPM for 20 s, fading out linearly over the last 8 s: the grid should reach close to the end.
        var s = TestMedia.clickSamples(bpm: 120, seconds: 20)
        let rate = 44100.0, fadeStart = Int(12 * rate)
        for i in fadeStart..<s.count { s[i] *= Float(1 - Double(i - fadeStart) / Double(s.count - fadeStart)) }
        let a = BeatDetector.analyze(samples: s, sampleRate: rate)
        #expect(a.beats.last! > 18.5, "last beat \(a.beats.last!)")
        let gaps = zip(a.beats, a.beats.dropFirst()).map { $1 - $0 }
        #expect(gaps.allSatisfy { abs($0 - 0.5) < 0.05 })
    }
}

@Suite struct EndToEndTests {
    @Test func probesPlansAndWritesValidFCPXML() async throws {
        let dir = try TestMedia.folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let drone = dir.appendingPathComponent("DJI_0001.mov"), phone = dir.appendingPathComponent("IMG_0002.mov")
        try await TestMedia.writeClip(to: phone, width: 360, height: 640, fps: 30, seconds: 4, created: "2026-11-10T10:00:05+0100")
        try await TestMedia.writeClip(to: drone, width: 640, height: 360, fps: 60, seconds: 3, created: "2026-11-10T10:00:00+0100")
        let songURL = dir.appendingPathComponent("song.wav")
        try TestMedia.writeWAV(TestMedia.clickSamples(bpm: 120, seconds: 12), to: songURL)
        let logoURL = dir.appendingPathComponent("logo.png")
        try TestMedia.writePNG(width: 800, height: 300, to: logoURL)

        let clips = sortedByCaptureTime([try await MediaProbe.clip(phone), try await MediaProbe.clip(drone)])
        #expect(clips.map(\.name) == ["DJI_0001", "IMG_0002"])
        #expect(clips[0].fps == 60 && clips[0].frameDuration == .fd60 && clips[0].speed == RationalTime(1, 2))
        #expect(clips[0].device == .dji && clips[1].device == .iPhone)
        #expect(clips[1].width == 360 && clips[1].height == 640)
        #expect(clips[1].duration == RationalTime(4))

        let song = try await MediaProbe.song(songURL)
        #expect(abs(song.duration.seconds - 12) < 0.01)
        let logo = try MediaProbe.logo(logoURL)
        #expect(logo.width == 800 && logo.height == 300)

        let beats = try BeatDetector.analyze(url: songURL).beats
        let plan = EditPlanner.plan(clips: clips, beats: beats, songDuration: song.duration.seconds, settings: PlanSettings())
        #expect(plan.slots.count == 2)
        #expect(plan.slots[0].speed == RationalTime(1, 2))
        let t = ReelTimelineBuilder.timeline(plan: plan, clips: clips, song: song, logo: logo, settings: PlanSettings(),
                                             projectName: "End to end")
        let xml = try FCPXMLWriter.document(for: t)
        if let dtd = FCPXMLValidator.dtdURL() { try FCPXMLValidator.validate(xml, dtd: dtd) }
        #expect(xml.contains("<timeMap>"))
        #expect(xml.contains(#"value="Beat 1""#))

        // The same timeline rendered straight to a video file: the reel's length, 1080×1920, the song.
        var tilted = t
        tilted.clips[1].transform = FCPTransform(scale: 1.1, rotation: 2, scaleEnd: 1.14)
        let movie = dir.appendingPathComponent("reel.mp4")
        try await ReelRenderer.render(tilted, to: movie)
        let rendered = AVURLAsset(url: movie)
        #expect(abs(try await rendered.load(.duration).seconds - t.duration.seconds) < 0.05)
        let v = try #require(try await rendered.loadTracks(withMediaType: .video).first)
        #expect(try await v.load(.naturalSize) == CGSize(width: 1080, height: 1920))
        #expect(try await rendered.loadTracks(withMediaType: .audio).count == 1)
    }
}

@Suite struct RenderPlacementTests {
    /// A portrait phone clip stored landscape with a 90° turn: upright, centred and filling 1080×1920.
    @Test func turnedClipFillsTheFrameUpright() {
        let preferred = CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: 2160, ty: 0)
        let m = ReelRenderer.placement(natural: CGSize(width: 3840, height: 2160), preferred: preferred,
                                       transform: .identity, scale: 1, frameW: 1080, frameH: 1920)
        let box = CGRect(x: 0, y: 0, width: 3840, height: 2160).applying(m)
        #expect(abs(box.minX) < 1e-6 && abs(box.minY) < 1e-6 && abs(box.width - 1080) < 1e-6 && abs(box.height - 1920) < 1e-6)
    }

    /// Final Cut's position is y up in percent of the height; the output has y down.
    @Test func positionMovesUpForPositiveY() {
        let m = ReelRenderer.placement(natural: CGSize(width: 1080, height: 1920), preferred: .identity,
                                       transform: FCPTransform(positionX: 10, positionY: 5), scale: 1, frameW: 1080, frameH: 1920)
        let centre = CGPoint(x: 540, y: 960).applying(m)
        #expect(abs(centre.x - (540 + 192)) < 1e-6 && abs(centre.y - (960 - 96)) < 1e-6)
    }
}

@Suite struct ProxyTests {
    @Test func makesProxyAndThumbnails() async throws {
        let dir = try TestMedia.folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let clip = dir.appendingPathComponent("IMG_0009.mov")
        try await TestMedia.writeClip(to: clip, width: 1280, height: 720, fps: 30, seconds: 2, created: "2026-11-10T10:00:00+0100")
        let cache = dir.appendingPathComponent("Proxies")
        #expect(!Proxies.exists(for: clip, folder: cache))
        let p = try await Proxies.make(for: clip, folder: cache)
        #expect(Proxies.exists(for: clip, folder: cache))
        #expect(try await Proxies.make(for: clip, folder: cache) == p)   // reused
        let thumbs = await Filmstrip.images(of: p, count: 6, height: 60)
        #expect(thumbs.count == 6)
    }
}
