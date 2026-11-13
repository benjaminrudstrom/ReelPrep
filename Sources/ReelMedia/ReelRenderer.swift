import AVFoundation
import CoreImage
import Foundation
import ImageIO
import QuartzCore
import FCPXMLKit

/// Renders a reel straight to a video file, for reels that need no grading: the same timeline the FCPXML is
/// written from (cuts with their in-points, 50 % slow motion, framing, tilt and zoom effect, empty slots
/// black, the logo over the intro and outro, the song with its beat-cut length), with AVFoundation.
/// What Final Cut adds and this doesn't: stabilization, colour grading, titles. Output is SDR Rec. 709
/// (HDR iPhone clips are converted), H.264 in an .mp4 or .mov, at the timeline's size and frame rate.
public enum ReelRenderer {
    public enum RenderError: Error, CustomStringConvertible {
        case noVideo(String), failed(String)
        public var description: String {
            switch self {
            case .noVideo(let n): return "\(n) has no video track."
            case .failed(let m): return "The render failed: \(m)"
            }
        }
    }

    /// Renders `timeline` to `url`; `progress` goes from 0 to 1. The song fades out over its last `songFadeOut` seconds.
    public static func render(_ timeline: FCPTimeline, to url: URL, songFadeOut: Double = 1,
                              progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws {
        let (composition, videoComposition, audioMix) = try await build(timeline, songFadeOut: songFadeOut)
        try? FileManager.default.removeItem(at: url)
        guard let session = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetHighestQuality) else {
            throw RenderError.failed("no export session")
        }
        session.videoComposition = videoComposition
        session.audioMix = audioMix
        session.outputURL = url
        session.outputFileType = url.pathExtension.lowercased() == "mov" ? .mov : .mp4
        session.shouldOptimizeForNetworkUse = true
        nonisolated(unsafe) let s = session
        let ticker = Task {
            while !Task.isCancelled {
                progress(Double(s.progress))
                try? await Task.sleep(for: .milliseconds(200))
            }
        }
        await s.export()
        ticker.cancel()
        if s.status != .completed {
            throw RenderError.failed(s.error?.localizedDescription ?? "status \(s.status.rawValue)")
        }
        progress(1)
    }

    /// The composition, its video composition (framing, logo) and audio mix (the song's fade-out).
    public static func build(_ t: FCPTimeline, songFadeOut: Double = 1) async throws
        -> (AVMutableComposition, AVMutableVideoComposition, AVMutableAudioMix?) {
        let W = Double(t.format.width), H = Double(t.format.height)
        let composition = AVMutableComposition()
        guard let video = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw RenderError.failed("no video track")
        }
        let black = CGColor(red: 0, green: 0, blue: 0, alpha: 1)
        var instructions: [AVMutableVideoCompositionInstruction] = []
        var cursor = CMTime.zero
        // The source assets must outlive the composition's edits (a released asset's track can't be inserted).
        var assets: [URL: AVURLAsset] = [:]
        func asset(_ url: URL) -> AVURLAsset {
            if let a = assets[url] { return a }
            let a = AVURLAsset(url: url)
            assets[url] = a
            return a
        }

        for c in t.clips {
            let duration = c.duration.cmTime
            let range = CMTimeRange(start: cursor, duration: duration)
            let instruction = AVMutableVideoCompositionInstruction()
            instruction.timeRange = range
            instruction.backgroundColor = black
            if c.isGap {
                video.insertEmptyTimeRange(range)
            } else {
                let a = t.assets[c.assetIndex]
                guard let source = try await asset(a.url).loadTracks(withMediaType: .video).first else {
                    throw RenderError.noVideo(a.name)
                }
                let (natural, preferred) = try await source.load(.naturalSize, .preferredTransform)
                let used = (c.duration * c.speed).cmTime
                let sourceRange = CMTimeRange(start: (c.sourceIn - a.start).cmTime, duration: used)
                do { try video.insertTimeRange(sourceRange, of: source, at: cursor) } catch {
                    throw RenderError.failed("\(c.name) \(sourceRange.start.seconds)+\(sourceRange.duration.seconds) s at \(cursor.seconds) s "
                                             + "(source \(try await source.load(.timeRange).duration.seconds) s): \(error.localizedDescription)")
                }
                if c.speed != RationalTime(1) {
                    video.scaleTimeRange(CMTimeRange(start: cursor, duration: used), toDuration: duration)
                }
                let layer = AVMutableVideoCompositionLayerInstruction(assetTrack: video)
                let place = { (scale: Double) in
                    placement(natural: natural, preferred: preferred, transform: c.transform, scale: scale, frameW: W, frameH: H)
                }
                if let end = c.transform.scaleEnd, end != c.transform.scale {
                    layer.setTransformRamp(fromStart: place(c.transform.scale), toEnd: place(end), timeRange: range)
                } else {
                    layer.setTransform(place(c.transform.scale), at: cursor)
                }
                instruction.layerInstructions = [layer]
            }
            instructions.append(instruction)
            cursor = cursor + duration
        }

        let vc = AVMutableVideoComposition()
        vc.renderSize = CGSize(width: W, height: H)
        vc.frameDuration = (t.format.frameDuration ?? .fd29_97).cmTime
        vc.instructions = instructions
        vc.colorPrimaries = AVVideoColorPrimaries_ITU_R_709_2
        vc.colorTransferFunction = AVVideoTransferFunction_ITU_R_709_2
        vc.colorYCbCrMatrix = AVVideoYCbCrMatrix_ITU_R_709_2

        // The logo: a layer over the video, shown while each overlay lasts.
        if !t.overlays.isEmpty {
            let parent = CALayer(), videoLayer = CALayer()
            parent.frame = CGRect(x: 0, y: 0, width: W, height: H)
            videoLayer.frame = parent.frame
            parent.addSublayer(videoLayer)
            for o in t.overlays {
                guard let image = loadImage(t.assets[o.assetIndex].url) else { continue }
                let iw = Double(image.width), ih = Double(image.height)
                // Final Cut fits a still into the frame; the overlay's scale is on top of that.
                let s = min(W / iw, H / ih) * o.transform.scale
                let layer = CALayer()
                layer.contents = image
                layer.contentsGravity = .resizeAspect
                // The animation tool's layers have y up, like Final Cut's position.
                layer.bounds = CGRect(x: 0, y: 0, width: iw * s, height: ih * s)
                layer.position = CGPoint(x: W / 2 + o.transform.positionX / 100 * H, y: H / 2 + o.transform.positionY / 100 * H)
                layer.opacity = 0
                let show = CABasicAnimation(keyPath: "opacity")
                show.fromValue = 1
                show.toValue = 1
                show.beginTime = o.start == .zero ? AVCoreAnimationBeginTimeAtZero : o.start.seconds
                show.duration = o.duration.seconds
                show.isRemovedOnCompletion = false
                show.fillMode = .removed
                layer.add(show, forKey: "show")
                parent.addSublayer(layer)
            }
            vc.animationTool = AVVideoCompositionCoreAnimationTool(postProcessingAsVideoLayer: videoLayer, in: parent)
        }

        // The song from its in-point for the reel's length (clip sound stays out, as in the FCPXML).
        var mix: AVMutableAudioMix?
        if let m = t.music {
            let a = t.assets[m.assetIndex]
            if let source = try await asset(a.url).loadTracks(withMediaType: .audio).first,
               let audio = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) {
                let available = a.duration == .zero ? m.duration : min(m.duration, a.duration - (m.sourceIn - a.start))
                let length = min(available.cmTime, cursor)
                do { try audio.insertTimeRange(CMTimeRange(start: (m.sourceIn - a.start).cmTime, duration: length), of: source, at: .zero) } catch {
                    throw RenderError.failed("song \((m.sourceIn - a.start).seconds)+\(length.seconds) s: \(error.localizedDescription)")
                }
                if songFadeOut > 0 {
                    let fade = CMTime(seconds: min(songFadeOut, length.seconds), preferredTimescale: 48000)
                    let params = AVMutableAudioMixInputParameters(track: audio)
                    params.setVolumeRamp(fromStartVolume: 1, toEndVolume: 0, timeRange: CMTimeRange(start: length - fade, duration: fade))
                    let audioMix = AVMutableAudioMix()
                    audioMix.inputParameters = [params]
                    mix = audioMix
                }
            }
        }
        return (composition, vc, mix)
    }

    /// Where a clip's frames go in the output: upright (the track's own rotation), centred, scaled to fill the
    /// frame times `scale`, turned counter-clockwise by the rotation, and moved by the position (Final Cut's
    /// units: percent of the frame height, y up). Output coordinates have y down.
    public static func placement(natural: CGSize, preferred: CGAffineTransform, transform: FCPTransform, scale: Double,
                                 frameW W: Double, frameH H: Double) -> CGAffineTransform {
        let shown = CGRect(origin: .zero, size: natural).applying(preferred)
        let w = abs(shown.width), h = abs(shown.height)
        let f = max(W / w, H / h) * scale
        return preferred
            .concatenating(CGAffineTransform(translationX: -shown.minX - w / 2, y: -shown.minY - h / 2))
            .concatenating(CGAffineTransform(scaleX: f, y: f))
            .concatenating(CGAffineTransform(rotationAngle: -transform.rotation * .pi / 180))
            .concatenating(CGAffineTransform(translationX: W / 2 + transform.positionX / 100 * H,
                                             y: H / 2 - transform.positionY / 100 * H))
    }

    static func loadImage(_ url: URL) -> CGImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(src, 0, nil)
    }
}

extension RationalTime {
    /// The same time as a CMTime: exact when the denominator fits a CMTime timescale.
    var cmTime: CMTime {
        if den <= Int64(Int32.max) { return CMTime(value: num, timescale: Int32(den)) }
        return CMTime(seconds: seconds, preferredTimescale: 240_000)
    }
}
