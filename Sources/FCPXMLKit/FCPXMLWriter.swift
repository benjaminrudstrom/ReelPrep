import Foundation

public enum FCPXMLError: Error, CustomStringConvertible {
    case emptyTimeline
    case anchorOutsideTimeline(String)
    case invalid(String)

    public var description: String {
        switch self {
        case .emptyTimeline: return "The timeline has no clips."
        case .anchorOutsideTimeline(let s): return "\(s) lies outside the timeline."
        case .invalid(let s): return s
        }
    }
}

/// Writes an `FCPTimeline` as FCPXML 1.14 (Final Cut Pro 12.4).
///
/// Structure: one event holding one project. Video cuts sit in the primary storyline (spine) as
/// `asset-clip`s, back to back, no transitions. The song is connected to the first cut on lane -1
/// and runs the whole project, carrying the beat markers. Logos are connected `video` items on lane 1,
/// anchored to the cut they start in.
public enum FCPXMLWriter {
    public static let version = "1.14"

    public static func document(for timeline: FCPTimeline) throws -> String {
        guard !timeline.clips.isEmpty else { throw FCPXMLError.emptyTimeline }

        // Resource ids: r1 = project format, then one format per distinct asset format, then assets.
        var formatIDs: [FCPFormat: String] = [timeline.format: "r1"]
        var formatOrder: [FCPFormat] = [timeline.format]
        var next = 2
        func formatID(_ f: FCPFormat) -> String {
            if let id = formatIDs[f] { return id }
            let id = "r\(next)"; next += 1
            formatIDs[f] = id; formatOrder.append(f)
            return id
        }
        var assetFormat: [Int: String] = [:]
        for (i, a) in timeline.assets.enumerated() {
            switch a.kind {
            case .video(let f, _, _, _), .still(let f): assetFormat[i] = formatID(f)
            case .audio: break
            }
        }
        var assetIDs: [String] = []
        for _ in timeline.assets { assetIDs.append("r\(next)"); next += 1 }

        var x = XMLBuilder()
        x.line(#"<?xml version="1.0" encoding="UTF-8"?>"#)
        x.line("<!DOCTYPE fcpxml>")
        x.line("")
        x.open("fcpxml", ["version": version])
        x.open("resources")
        for f in formatOrder {
            x.empty("format", [
                ("id", formatIDs[f]!), ("name", f.name), ("frameDuration", f.frameDuration?.fcpxml),
                ("width", String(f.width)), ("height", String(f.height)), ("colorSpace", f.colorSpace),
            ])
        }
        for (i, a) in timeline.assets.enumerated() {
            var attrs: [(String, String?)] = [("id", assetIDs[i]), ("name", a.name), ("start", a.start.fcpxml),
                                              ("duration", a.duration.fcpxml)]
            switch a.kind {
            case .video(_, let hasAudio, let ch, let rate):
                attrs += [("hasVideo", "1"), ("format", assetFormat[i]), ("videoSources", "1")]
                if hasAudio {
                    attrs += [("hasAudio", "1"), ("audioSources", "1"),
                              ("audioChannels", ch.map(String.init)), ("audioRate", rate.map(String.init))]
                }
            case .audio(let ch, let rate):
                attrs += [("hasAudio", "1"), ("audioSources", "1"), ("audioChannels", String(ch)),
                          ("audioRate", String(rate))]
            case .still:
                attrs += [("hasVideo", "1"), ("format", assetFormat[i]), ("videoSources", "1")]
            }
            x.open("asset", attrs)
            x.empty("media-rep", [("kind", "original-media"), ("src", a.url.absoluteURL.absoluteString)])
            x.close("asset")
        }
        x.close("resources")

        if let lib = timeline.libraryLocation {
            var loc = lib.absoluteURL.absoluteString
            if !loc.hasSuffix("/") { loc += "/" }
            x.open("library", ["location": loc])
        }
        x.open("event", ["name": timeline.eventName])
        x.open("project", ["name": timeline.projectName])
        let total = timeline.duration
        x.open("sequence", [("format", "r1"), ("duration", total.fcpxml), ("tcStart", "0s"), ("tcFormat", "NDF"),
                            ("audioLayout", "stereo"), ("audioRate", "48k")])
        x.open("spine")

        // Timeline offsets of each cut.
        var offsets: [RationalTime] = []
        var t = RationalTime.zero
        for c in timeline.clips { offsets.append(t); t = t + c.duration }

        func parentIndex(for time: RationalTime) -> Int? {
            for i in timeline.clips.indices.reversed() where offsets[i] <= time { return time < total ? i : nil }
            return nil
        }
        var overlaysByParent: [Int: [FCPOverlay]] = [:]
        for o in timeline.overlays {
            guard let p = parentIndex(for: o.start) else { throw FCPXMLError.anchorOutsideTimeline("Overlay \(o.name)") }
            overlaysByParent[p, default: []].append(o)
        }

        for (i, c) in timeline.clips.enumerated() {
            if c.isGap {
                // An empty slot: a gap, its local time starting at 0; anchored items as for clips.
                func local(_ timelineTime: RationalTime) -> RationalTime { timelineTime - offsets[i] }
                x.open("gap", [("name", c.name), ("offset", offsets[i].fcpxml), ("start", "0s"), ("duration", c.duration.fcpxml)])
                writeAnchored(&x, i: i, local: local)
                x.close("gap")
                continue
            }
            let asset = timeline.assets[c.assetIndex]
            guard c.speed.num > 0 else { throw FCPXMLError.invalid("Clip \(c.name) has speed \(c.speed)") }
            let sourceUsed = c.duration * c.speed
            guard c.sourceIn >= asset.start, c.sourceIn + sourceUsed <= asset.start + asset.duration else {
                throw FCPXMLError.invalid("Clip \(c.name): source range \(c.sourceIn)+\(sourceUsed) outside the file")
            }
            // With a retime, the clip's local time ("start") is the retimed time; the timeMap maps it
            // back to the file's time. Both start at the asset's start.
            let retimed = c.speed != RationalTime(1)
            let localStart = retimed ? asset.start + (c.sourceIn - asset.start) / c.speed : c.sourceIn
            func local(_ timelineTime: RationalTime) -> RationalTime { localStart + (timelineTime - offsets[i]) }

            x.open("asset-clip", [("ref", assetIDs[c.assetIndex]), ("offset", offsets[i].fcpxml), ("name", c.name),
                                  ("start", localStart.fcpxml), ("duration", c.duration.fcpxml),
                                  ("format", assetFormat[c.assetIndex]), ("tcFormat", "NDF")])
            if retimed {
                x.open("timeMap")
                x.empty("timept", [("time", asset.start.fcpxml), ("value", asset.start.fcpxml), ("interp", "smooth2")])
                x.empty("timept", [("time", (asset.start + asset.duration / c.speed).fcpxml),
                                   ("value", (asset.start + asset.duration).fcpxml), ("interp", "smooth2")])
                x.close("timeMap")
            }
            x.empty("adjust-conform", [("type", "fill")])
            let transformAttributes = [("position", pair(c.transform.positionX, c.transform.positionY)),
                                       ("scale", pair(c.transform.scale, c.transform.scale))]
                + (c.transform.rotation != 0 ? [("rotation", number(c.transform.rotation))] : [])
            if let end = c.transform.scaleEnd, end != c.transform.scale {
                // A slow push in or pull out: the scale keyframed linearly from the first frame to the end,
                // in the clip's local time.
                x.open("adjust-transform", transformAttributes)
                x.open("param", [("name", "scale")])
                x.open("keyframeAnimation")
                x.empty("keyframe", [("time", localStart.fcpxml), ("value", pair(c.transform.scale, c.transform.scale)), ("curve", "linear")])
                x.empty("keyframe", [("time", (localStart + c.duration).fcpxml), ("value", pair(end, end)), ("curve", "linear")])
                x.close("keyframeAnimation")
                x.close("param")
                x.close("adjust-transform")
            } else {
                x.empty("adjust-transform", transformAttributes)
            }
            if c.stabilize { x.empty("adjust-stabilization", [("type", "automatic")]) }
            if let db = c.volumeDB { x.empty("adjust-volume", [("amount", "\(number(db))dB")]) }

            writeAnchored(&x, i: i, local: local)
            x.close("asset-clip")
        }
        x.close("spine")
        x.close("sequence")
        x.close("project")
        x.close("event")
        if timeline.libraryLocation != nil { x.close("library") }
        x.close("fcpxml")
        return x.text

        /// Connected items: logos above, the song below (on the first cut).
        func writeAnchored(_ x: inout XMLBuilder, i: Int, local: (RationalTime) -> RationalTime) {
            for o in overlaysByParent[i] ?? [] {
                x.open("video", [("ref", assetIDs[o.assetIndex]), ("lane", "1"), ("offset", local(o.start).fcpxml),
                                 ("name", o.name), ("start", "0s"), ("duration", o.duration.fcpxml)])
                x.empty("adjust-transform", [("position", pair(o.transform.positionX, o.transform.positionY)),
                                             ("scale", pair(o.transform.scale, o.transform.scale))])
                x.close("video")
            }
            if i == 0, let m = timeline.music {
                x.open("asset-clip", [("ref", assetIDs[m.assetIndex]), ("lane", "-1"), ("offset", local(.zero).fcpxml),
                                      ("name", m.name), ("start", m.sourceIn.fcpxml), ("duration", m.duration.fcpxml),
                                      ("audioRole", "music")])
                for mk in m.markers {
                    x.empty("marker", [("start", (m.sourceIn + mk.time).fcpxml), ("duration", timeline.format.frameDuration?.fcpxml ?? "1001/30000s"),
                                       ("value", mk.name)])
                }
                x.close("asset-clip")
            }
        }
    }

    package static func number(_ v: Double) -> String {
        if v == v.rounded() && Swift.abs(v) < 1e12 { return String(Int64(v)) }
        var s = String(format: "%.4f", v)
        while s.hasSuffix("0") { s.removeLast() }
        if s.hasSuffix(".") { s.removeLast() }
        return s
    }

    static func pair(_ a: Double, _ b: Double) -> String { "\(number(a)) \(number(b))" }
}

/// Minimal indented XML writer with attribute escaping (shared with the FCP7 XML writer).
package struct XMLBuilder {
    package var text = ""
    var depth = 0

    package init() {}

    package mutating func line(_ s: String) { text += s + "\n" }

    package static func escape(_ s: String) -> String {
        var out = ""
        for ch in s {
            switch ch {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            default: out.append(ch)
            }
        }
        return out
    }

    func tag(_ name: String, _ attrs: [(String, String?)]) -> String {
        var s = "<" + name
        for (k, v) in attrs { if let v { s += " \(k)=\"\(XMLBuilder.escape(v))\"" } }
        return s
    }

    package mutating func open(_ name: String, _ attrs: [(String, String?)] = []) {
        line(String(repeating: "    ", count: depth) + tag(name, attrs) + ">")
        depth += 1
    }

    package mutating func open(_ name: String, _ attrs: KeyValuePairs<String, String>) {
        open(name, attrs.map { ($0.key, Optional($0.value)) })
    }

    package mutating func empty(_ name: String, _ attrs: [(String, String?)]) {
        line(String(repeating: "    ", count: depth) + tag(name, attrs) + "/>")
    }

    package mutating func close(_ name: String) {
        depth -= 1
        line(String(repeating: "    ", count: depth) + "</\(name)>")
    }

    /// `<name>value</name>` on one line, the value escaped.
    package mutating func element(_ name: String, _ value: String, _ attrs: [(String, String?)] = []) {
        line(String(repeating: "    ", count: depth) + tag(name, attrs) + ">" + XMLBuilder.escape(value) + "</\(name)>")
    }
}
