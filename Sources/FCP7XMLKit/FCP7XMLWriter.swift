import Foundation
import FCPXMLKit

/// Writes an `FCPTimeline` as Final Cut Pro 7 XML (`<xmeml version="4">`), the interchange format Adobe Premiere Pro
/// imports (File > Import) and DaVinci Resolve reads too (File > Import > Timeline).
///
/// Structure: one sequence at the timeline's format (1080×1920, 29.97 fps). Video track 1 holds the cuts back to back
/// (an empty slot is simply no clip there), video track 2 the logo stills, audio track 1 the song; the beats are
/// sequence markers. Everything is counted in frames of the sequence's rate.
///
/// What doesn't carry over: stabilization (no XML for Warp Stabilizer / Resolve's stabilizer; apply it in the
/// editor) and the clips' own sound (left out, as it is muted in Final Cut).
///
/// Written from the FCP7 XML format as documented and as Premiere exports it, without a reference export from this
/// reel yet. The values to check on the first import are listed in DECISIONS.md (2026-11-13).
public enum FCP7XMLWriter {
    public static let version = "4"

    public enum WriteError: Error, CustomStringConvertible {
        case emptyTimeline
        case noFrameRate
        public var description: String {
            switch self {
            case .emptyTimeline: return "The timeline has no clips."
            case .noFrameRate: return "The timeline's format has no frame rate."
            }
        }
    }

    public static func document(for timeline: FCPTimeline) throws -> String {
        guard !timeline.clips.isEmpty else { throw WriteError.emptyTimeline }
        guard let fd = timeline.format.frameDuration else { throw WriteError.noFrameRate }
        let W = Double(timeline.format.width), H = Double(timeline.format.height)
        func frames(_ t: RationalTime) -> Int64 { roundedFrames(t, fd) }
        let total = frames(timeline.duration)

        var x = XMLBuilder()
        x.line(#"<?xml version="1.0" encoding="UTF-8"?>"#)
        x.line("<!DOCTYPE xmeml>")
        x.open("xmeml", [("version", version)])
        x.open("sequence", [("id", "sequence-1")])
        x.element("name", timeline.projectName)
        x.element("duration", String(total))
        rate(&x, fd)
        x.open("timecode")
        rate(&x, fd)
        x.element("string", "00:00:00:00")
        x.element("frame", "0")
        x.element("displayformat", "NDF")
        x.close("timecode")
        x.open("media")

        // Video
        x.open("video")
        x.open("format")
        x.open("samplecharacteristics")
        rate(&x, fd)
        x.element("width", String(timeline.format.width))
        x.element("height", String(timeline.format.height))
        x.element("anamorphic", "FALSE")
        x.element("pixelaspectratio", "square")
        x.element("fielddominance", "none")
        x.element("colordepth", "24")
        x.close("samplecharacteristics")
        x.close("format")

        var writtenFiles = Set<Int>()
        var itemID = 0
        func nextItem() -> String { itemID += 1; return "clipitem-\(itemID)" }

        x.open("track")
        var t = RationalTime.zero
        for c in timeline.clips {
            defer { t = t + c.duration }
            if c.isGap { continue }
            let asset = timeline.assets[c.assetIndex]
            let start = frames(t), end = frames(t + c.duration)
            // In and out are in the clip's own (retimed) frames from the start of the file: for 50 % slow motion
            // the source time is doubled, so out − in stays the length on the timeline.
            let inF = frames((c.sourceIn - asset.start) / c.speed)
            let outF = inF + (end - start)
            x.open("clipitem", [("id", nextItem())])
            x.element("masterclipid", "masterclip-\(c.assetIndex + 1)")
            x.element("name", c.name)
            x.element("enabled", "TRUE")
            x.element("duration", String(frames(asset.duration / c.speed)))
            rate(&x, fd)
            x.element("start", String(start))
            x.element("end", String(end))
            x.element("in", String(inF))
            x.element("out", String(outF))
            file(&x, index: c.assetIndex, asset: asset, fd: fd, written: &writtenFiles)

            // Basic Motion: scale 100 is the file at its own pixel size, so "fill" is folded into it.
            let (w, h) = size(asset)
            let fill = max(W / w, H / h) * 100
            let center = centre(c.transform, W: W, H: H)
            motion(&x, scale: fill * c.transform.scale,
                   scaleEnd: c.transform.scaleEnd.flatMap { $0 != c.transform.scale ? fill * $0 : nil },
                   keyframeFrames: (inF, outF), rotation: -c.transform.rotation, center: center)
            if c.speed != RationalTime(1) { timeRemap(&x, percent: c.speed.seconds * 100) }
            x.close("clipitem")
        }
        x.element("enabled", "TRUE")
        x.element("locked", "FALSE")
        x.close("track")

        // The logo stills, above the cuts.
        if !timeline.overlays.isEmpty {
            x.open("track")
            for o in timeline.overlays {
                let asset = timeline.assets[o.assetIndex]
                let start = frames(o.start), end = frames(o.start + o.duration)
                x.open("clipitem", [("id", nextItem())])
                x.element("masterclipid", "masterclip-\(o.assetIndex + 1)")
                x.element("name", o.name)
                x.element("enabled", "TRUE")
                x.element("duration", String(end - start))
                rate(&x, fd)
                x.element("start", String(start))
                x.element("end", String(end))
                x.element("in", "0")
                x.element("out", String(end - start))
                x.element("stillframe", "TRUE")
                file(&x, index: o.assetIndex, asset: asset, fd: fd, written: &writtenFiles, stillFrames: end - start)
                // Final Cut fits a still into the frame and the overlay's scale is on top of that.
                let (w, h) = size(asset)
                let fit = min(W / w, H / h) * 100
                motion(&x, scale: fit * o.transform.scale, scaleEnd: nil, keyframeFrames: (0, 0),
                       rotation: -o.transform.rotation, center: centre(o.transform, W: W, H: H))
                x.close("clipitem")
            }
            x.element("enabled", "TRUE")
            x.element("locked", "FALSE")
            x.close("track")
        }
        x.close("video")

        // Audio: the song only (the clips' sound is muted in the reel).
        x.open("audio")
        x.element("numOutputChannels", "2")
        x.open("format")
        x.open("samplecharacteristics")
        x.element("depth", "16")
        x.element("samplerate", "48000")
        x.close("samplecharacteristics")
        x.close("format")
        if let m = timeline.music {
            let asset = timeline.assets[m.assetIndex]
            x.open("track")
            let inF = frames(m.sourceIn)
            let length = frames(m.duration)
            x.open("clipitem", [("id", nextItem())])
            x.element("masterclipid", "masterclip-\(m.assetIndex + 1)")
            x.element("name", m.name)
            x.element("enabled", "TRUE")
            x.element("duration", String(frames(asset.duration)))
            rate(&x, fd)
            x.element("start", "0")
            x.element("end", String(length))
            x.element("in", String(inF))
            x.element("out", String(inF + length))
            file(&x, index: m.assetIndex, asset: asset, fd: fd, written: &writtenFiles)
            x.open("sourcetrack")
            x.element("mediatype", "audio")
            x.element("trackindex", "1")
            x.close("sourcetrack")
            x.close("clipitem")
            x.element("enabled", "TRUE")
            x.element("locked", "FALSE")
            x.close("track")
        }
        x.close("audio")
        x.close("media")

        // The beats, as sequence markers (timeline time).
        if let m = timeline.music {
            for mk in m.markers {
                let f = frames(mk.time)
                guard f >= 0, f < total else { continue }
                x.open("marker")
                x.element("name", mk.name)
                x.element("comment", "")
                x.element("in", String(f))
                x.element("out", "-1")
                x.close("marker")
            }
        }
        x.close("sequence")
        x.close("xmeml")
        return x.text
    }

    /// Nearest whole frame of `fd` in `t`.
    static func roundedFrames(_ t: RationalTime, _ fd: RationalTime) -> Int64 {
        let q = t / fd
        let twice = 2 * q.num + (q.num >= 0 ? q.den : -q.den)
        return twice / (2 * q.den)
    }

    /// `<rate>`: 29.97 is timebase 30 with ntsc TRUE.
    static func rate(_ x: inout XMLBuilder, _ fd: RationalTime) {
        let ntsc = fd.num % 1001 == 0
        let timebase = ntsc ? (fd.den * 1001 / fd.num + 500) / 1000 : (fd.den + fd.num / 2) / fd.num
        x.open("rate")
        x.element("timebase", String(timebase))
        x.element("ntsc", ntsc ? "TRUE" : "FALSE")
        x.close("rate")
    }

    /// `file://localhost/…`, as Premiere writes it.
    static func pathURL(_ url: URL) -> String {
        let path = url.standardizedFileURL.path
        let encoded = path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "&;=+$,"))) ?? path
        return "file://localhost" + encoded
    }

    /// The file, in full the first time and by id after that.
    static func file(_ x: inout XMLBuilder, index: Int, asset: FCPAsset, fd: RationalTime, written: inout Set<Int>,
                     stillFrames: Int64? = nil) {
        let id = "file-\(index + 1)"
        guard !written.contains(index) else { x.empty("file", [("id", id)]); return }
        written.insert(index)
        x.open("file", [("id", id)])
        x.element("name", asset.url.lastPathComponent)
        x.element("pathurl", pathURL(asset.url))
        rate(&x, fd)
        x.element("duration", String(stillFrames ?? roundedFrames(asset.duration, fd)))
        x.open("media")
        switch asset.kind {
        case let .video(f, hasAudio, channels, audioRate):
            video(&x, f)
            if hasAudio {
                x.open("audio")
                x.open("samplecharacteristics")
                x.element("depth", "16")
                x.element("samplerate", String(audioRate ?? 48000))
                x.close("samplecharacteristics")
                x.element("channelcount", String(channels ?? 2))
                x.close("audio")
            }
        case let .still(f):
            video(&x, f)
        case let .audio(channels, rate):
            x.open("audio")
            x.open("samplecharacteristics")
            x.element("depth", "16")
            x.element("samplerate", String(rate))
            x.close("samplecharacteristics")
            x.element("channelcount", String(channels))
            x.close("audio")
        }
        x.close("media")
        x.close("file")

        func video(_ x: inout XMLBuilder, _ f: FCPFormat) {
            x.open("video")
            x.open("samplecharacteristics")
            x.element("width", String(f.width))
            x.element("height", String(f.height))
            x.element("anamorphic", "FALSE")
            x.element("pixelaspectratio", "square")
            x.element("fielddominance", "none")
            x.close("samplecharacteristics")
            x.close("video")
        }
    }

    /// The upright pixel size of a video or still asset.
    static func size(_ asset: FCPAsset) -> (Double, Double) {
        switch asset.kind {
        case let .video(f, _, _, _), let .still(f): return (Double(max(f.width, 1)), Double(max(f.height, 1)))
        case .audio: return (1, 1)
        }
    }

    /// Final Cut's position (percent of the frame height, y up) as FCP7's centre: a share of the frame's width
    /// and height from the middle, y down.
    static func centre(_ t: FCPTransform, W: Double, H: Double) -> (Double, Double) {
        (t.positionX / 100 * H / W, -t.positionY / 100)
    }

    /// The Basic Motion filter: scale in percent of the file's own size, rotation in degrees clockwise, centre.
    /// With `scaleEnd`, the scale is keyframed linearly from the in to the out point (the zoom effect).
    static func motion(_ x: inout XMLBuilder, scale: Double, scaleEnd: Double?, keyframeFrames: (Int64, Int64),
                       rotation: Double, center: (Double, Double)) {
        let n = FCPXMLWriter.number
        x.open("filter")
        x.open("effect")
        x.element("name", "Basic Motion")
        x.element("effectid", "basic")
        x.element("effectcategory", "motion")
        x.element("effecttype", "motion")
        x.element("mediatype", "video")
        x.open("parameter", [("authoringApp", "PremierePro")])
        x.element("parameterid", "scale")
        x.element("name", "Scale")
        x.element("valuemin", "0")
        x.element("valuemax", "1000")
        x.element("value", n(scale))
        if let end = scaleEnd {
            for (when, v) in [(keyframeFrames.0, scale), (keyframeFrames.1, end)] {
                x.open("keyframe")
                x.element("when", String(when))
                x.element("value", n(v))
                x.close("keyframe")
            }
        }
        x.close("parameter")
        x.open("parameter", [("authoringApp", "PremierePro")])
        x.element("parameterid", "rotation")
        x.element("name", "Rotation")
        x.element("valuemin", "-8640")
        x.element("valuemax", "8640")
        x.element("value", n(rotation))
        x.close("parameter")
        x.open("parameter", [("authoringApp", "PremierePro")])
        x.element("parameterid", "center")
        x.element("name", "Center")
        x.open("value")
        x.element("horiz", n(center.0))
        x.element("vert", n(center.1))
        x.close("value")
        x.close("parameter")
        x.close("effect")
        x.close("filter")
    }

    /// Constant speed (50 for 50 % slow motion), as the Time Remap filter.
    static func timeRemap(_ x: inout XMLBuilder, percent: Double) {
        let n = FCPXMLWriter.number
        x.open("filter")
        x.open("effect")
        x.element("name", "Time Remap")
        x.element("effectid", "timeremap")
        x.element("effectcategory", "motion")
        x.element("effecttype", "motion")
        x.element("mediatype", "video")
        x.open("parameter", [("authoringApp", "PremierePro")])
        x.element("parameterid", "variablespeed")
        x.element("name", "variablespeed")
        x.element("valuemin", "0")
        x.element("valuemax", "1")
        x.element("value", "0")
        x.close("parameter")
        x.open("parameter", [("authoringApp", "PremierePro")])
        x.element("parameterid", "speed")
        x.element("name", "speed")
        x.element("valuemin", "-100000")
        x.element("valuemax", "100000")
        x.element("value", n(percent))
        x.close("parameter")
        x.open("parameter", [("authoringApp", "PremierePro")])
        x.element("parameterid", "reverse")
        x.element("name", "reverse")
        x.element("value", "FALSE")
        x.close("parameter")
        x.open("parameter", [("authoringApp", "PremierePro")])
        x.element("parameterid", "frameblending")
        x.element("name", "frameblending")
        x.element("value", "FALSE")
        x.close("parameter")
        x.close("effect")
        x.close("filter")
    }
}
