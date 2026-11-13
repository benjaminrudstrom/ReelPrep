import Foundation
import FCPXMLKit

public struct PlanSettings: Sendable, Codable, Equatable {
    /// Longest cut, in beats (with `fixedCuts`: every cut is exactly this long).
    public var beatsPerCut: Int = 4
    /// Shortest cut in seconds when fitting the clips to the song (about: 10 % under is allowed).
    public var minCutLength: Double = 1.0
    /// Cut every `beatsPerCut` beats instead of fitting the clips to the song.
    public var fixedCuts: Bool = false
    /// Start the song at this detected beat (0-based); nil starts at the song's first frame.
    public var songStartBeat: Int?
    /// Longest reel in seconds; nil = as long as the clips and the song allow.
    public var maxLength: Double?
    /// Intro logo cuts out after this many beats; nil = at the end of the first cut.
    public var introBeats: Int?
    /// Outro logo cuts in this many beats before the end; nil = at the start of the last cut.
    public var outroBeats: Int?
    /// Show the logo at the start / at the end.
    public var showIntroLogo = true
    public var showOutroLogo = true
    /// Logo width as a share of the frame width.
    public var logoWidth: Double = 0.66
    /// Apply FCP's automatic stabilization to every cut.
    public var stabilize: Bool = true

    public init() {}
}

/// One cut on the timeline, in timeline frames.
public struct Slot: Sendable, Equatable {
    public var clipIndex: Int
    public var startFrame: Int64
    public var endFrame: Int64
    public var beats: Int
    /// In-point in the file's own time.
    public var sourceIn: RationalTime
    public var speed: RationalTime
}

public struct ReelPlan: Sendable {
    public var frameDuration: RationalTime
    public var slots: [Slot]
    /// Timeline frames of the beats within the reel (for markers).
    public var beatFrames: [Int64]
    /// Timeline frames of every usable beat in the song (also past the reel's end), for snapping.
    public var beatGrid: [Int64] = []
    /// Where in the song the reel starts, in frames of song time.
    public var songInFrames: Int64
    public var introEndFrame: Int64?
    public var outroStartFrame: Int64?
    public var warnings: [String]

    public var totalFrames: Int64 { slots.last?.endFrame ?? 0 }
    public var duration: RationalTime { frameDuration * totalFrames }
}

/// Lays the clips (in order) onto the beats with hard cuts and centred source windows. By default each
/// cut gets the beats left in the song shared over the clips left (between about `minCutLength` seconds
/// and `beatsPerCut` beats), so as many clips as possible fit; with `fixedCuts` every cut is N beats.
/// A cut is shortened to fewer whole beats when its clip is too short, skipped when it can't fill one.
public enum EditPlanner {
    /// `inPoints`: where the user wants a clip's window to start, in seconds from the clip's start
    /// (by clip index); clamped so the window fits. Clips without one are centred.
    public static func plan(clips: [ClipInfo], beats: [Double], songDuration: Double, settings: PlanSettings,
                            inPoints: [Int: Double] = [:], beatCounts: [Int: Int] = [:],
                            frameDuration: RationalTime = .fd29_97) -> ReelPlan {
        var warnings: [String] = []
        let fd = frameDuration
        let n = max(1, settings.beatsPerCut)

        // Song start, snapped to the frame grid.
        var songStart = 0.0
        if let b = settings.songStartBeat {
            if b >= 0 && b < beats.count { songStart = beats[b] } else {
                warnings.append("Song start beat \(b) doesn't exist (song has \(beats.count) beats); starting at 0 s.")
            }
        }
        let songIn = RationalTime.roundFrames(songStart, frameDuration: fd)
        var limit = Int64((songDuration / fd.seconds).rounded(.down)) - songIn
        if let maxLen = settings.maxLength { limit = min(limit, Int64((maxLen / fd.seconds).rounded(.down))) }

        // Beats on the timeline (frames > 0, within the song and length limit), unique and sorted.
        var tb: [Int64] = []
        for b in beats.sorted() {
            let f = RationalTime.roundFrames(b, frameDuration: fd) - songIn
            if f > 0 && f <= limit && f != tb.last { tb.append(f) }
        }

        // Shortest cut in beats: the fewest beats that last about minCutLength.
        var minBeats = n
        if !settings.fixedCuts && tb.count >= 2 {
            let gaps = zip(tb, tb.dropFirst()).map { $1 - $0 }.sorted()
            let beatSeconds = (fd * gaps[gaps.count / 2]).seconds
            minBeats = min(n, max(1, Int((0.9 * settings.minCutLength / beatSeconds).rounded(.up))))
        }

        var slots: [Slot] = []
        var cur: Int64 = 0
        var curBeat = -1   // index in tb of the beat at `cur`; -1 is the first frame
        for (ci, clip) in clips.enumerated() {
            // Share the beats left over the clips left, within [minBeats, n].
            let beatsLeft = tb.count - 1 - curBeat
            let share = Int((Double(beatsLeft) / Double(clips.count - ci)).rounded())
            // A length the user set by dragging the cut's edge wins (as far as the song allows).
            let want = beatCounts[ci].map { max(1, $0) } ?? (settings.fixedCuts ? n : min(n, max(minBeats, share)))
            // Too few beats left (song or length limit): end the reel on the last full cut.
            if want > beatsLeft {
                warnings.append("Not enough beats left for \(clip.name) and later clips; the reel ends at \(fmt(fd * cur)).")
                break
            }
            var target = curBeat + want
            // The first cut starts at the first frame, not on a beat: make sure it lasts the minimum too.
            while beatCounts[ci] == nil, !settings.fixedCuts, target < tb.count - 1, target - curBeat < n,
                  (fd * (tb[target] - cur)).seconds < 0.9 * settings.minCutLength { target += 1 }
            var j = target
            func fits(_ endFrame: Int64) -> Bool { fd * (endFrame - cur) * clip.speed <= clip.duration }
            while j > curBeat && !fits(tb[j]) { j -= 1 }
            if j == curBeat {
                warnings.append("Skipped \(clip.name): \(fmt(clip.duration)) is too short for even one beat"
                                + (clip.speed != RationalTime(1) ? " at 50 % speed." : "."))
                continue
            }
            if j < target {
                warnings.append("Shortened \(clip.name)'s cut to \(j - curBeat) beat(s): the clip is \(fmt(clip.duration))"
                                + (clip.speed != RationalTime(1) ? " (at 50 % speed it fills half as much)." : "."))
            }
            let end = tb[j]
            let needed = fd * (end - cur) * clip.speed
            let sourceIn = windowStart(clip: clip, needed: needed, wanted: inPoints[ci])
            slots.append(Slot(clipIndex: ci, startFrame: cur, endFrame: end, beats: j - curBeat,
                              sourceIn: sourceIn, speed: clip.speed))
            cur = end
            curBeat = j
        }

        let total = cur
        var intro: Int64?
        var outro: Int64?
        if settings.showIntroLogo, let first = slots.first {
            if let ib = settings.introBeats, ib > 0 {
                intro = tb.indices.contains(ib - 1) ? min(tb[ib - 1], total) : first.endFrame
            } else {
                intro = first.endFrame
            }
        }
        if settings.showOutroLogo, slots.count >= 2 || !settings.showIntroLogo, let last = slots.last {
            if let ob = settings.outroBeats, ob > 0, let endIdx = tb.firstIndex(of: total), endIdx - ob >= -1 {
                outro = endIdx - ob >= 0 ? tb[endIdx - ob] : 0
            } else {
                outro = last.startFrame
            }
            if let i = intro, let o = outro, o < i {
                warnings.append("Intro and outro logos overlap; the outro starts where the intro ends.")
                outro = i
            }
            if outro == total { outro = nil }
        }

        var plan = ReelPlan(frameDuration: fd, slots: slots, beatFrames: tb.filter { $0 <= total }, songInFrames: songIn,
                            introEndFrame: intro, outroStartFrame: outro, warnings: warnings)
        plan.beatGrid = tb
        return plan
    }

    /// Start of a `needed`-long window in the clip, on the clip's frame grid: at `wanted` seconds from the
    /// clip's start (clamped so it fits), or centred.
    public static func windowStart(clip: ClipInfo, needed: RationalTime, wanted: Double?) -> RationalTime {
        let maxK = max(0, (clip.duration - needed).floorDiv(clip.frameDuration))
        let k: Int64
        if let w = wanted {
            k = min(max(0, Int64((w / clip.frameDuration.seconds).rounded())), maxK)
        } else {
            k = ((clip.duration - needed) / RationalTime(2)).floorDiv(clip.frameDuration)
        }
        return clip.start + clip.frameDuration * max(0, k)
    }

    static func fmt(_ t: RationalTime) -> String { String(format: "%.2f s", t.seconds) }
}

/// Turns a plan into the FCPXML timeline.
public enum ReelTimelineBuilder {
    public static func timeline(plan: ReelPlan, clips: [ClipInfo], song: SongInfo, logo: LogoInfo?,
                                settings: PlanSettings, projectName: String, eventName: String = "ReelPrep",
                                transforms: [Int: FCPTransform] = [:], format: FCPFormat = .reel2997) -> FCPTimeline {
        let fd = plan.frameDuration
        var assets: [FCPAsset] = []
        var assetOfClip: [Int: Int] = [:]
        for s in plan.slots where assetOfClip[s.clipIndex] == nil && !clips[s.clipIndex].isPlaceholder {
            let c = clips[s.clipIndex]
            assetOfClip[s.clipIndex] = assets.count
            assets.append(FCPAsset(name: c.name, url: c.url, start: c.start, duration: c.duration,
                                   kind: .video(c.format, hasAudio: c.hasAudio, audioChannels: c.audioChannels,
                                                audioRate: c.audioRate)))
        }
        let spine = plan.slots.map { s in
            clips[s.clipIndex].isPlaceholder ? FCPSpineClip.gap(duration: fd * (s.endFrame - s.startFrame)) :
            FCPSpineClip(assetIndex: assetOfClip[s.clipIndex]!, name: clips[s.clipIndex].name,
                         duration: fd * (s.endFrame - s.startFrame), sourceIn: s.sourceIn, speed: s.speed,
                         transform: transforms[s.clipIndex] ?? .identity, stabilize: settings.stabilize, volumeDB: -96)  // clip sound always muted (the user, 2026-11-10)
        }

        let songIndex = assets.count
        assets.append(FCPAsset(name: song.name, url: song.url, duration: song.duration,
                               kind: .audio(channels: song.channels, rate: song.sampleRate)))
        let markers = plan.beatFrames.enumerated().map { FCPMarker(time: fd * $0.element, name: "Beat \($0.offset + 1)") }
        let music = FCPMusic(assetIndex: songIndex, name: song.name, sourceIn: fd * plan.songInFrames,
                             duration: plan.duration, markers: markers)

        var overlays: [FCPOverlay] = []
        if let logo {
            let logoIndex = assets.count
            let fmt = FCPFormat(name: "FFVideoFormatRateUndefined", frameDuration: nil, width: logo.width,
                                height: logo.height, colorSpace: "1-13-1")
            assets.append(FCPAsset(name: logo.name, url: logo.url, duration: .zero, kind: .still(fmt)))
            let t = FCPTransform(scale: logoScale(logo: logo, frameWidth: format.width, frameHeight: format.height,
                                                  widthShare: settings.logoWidth))
            if let e = plan.introEndFrame, e > 0 {
                overlays.append(FCPOverlay(assetIndex: logoIndex, name: "\(logo.name) (intro)", start: .zero,
                                           duration: fd * e, transform: t))
            }
            if let o = plan.outroStartFrame, o < plan.totalFrames {
                overlays.append(FCPOverlay(assetIndex: logoIndex, name: "\(logo.name) (outro)", start: fd * o,
                                           duration: fd * (plan.totalFrames - o), transform: t))
            }
        }
        return FCPTimeline(eventName: eventName, projectName: projectName, format: format, assets: assets,
                           clips: spine, overlays: overlays, music: music)
    }

    /// FCP fits a still into the frame (whole image visible); this is the scale on top of that
    /// which makes the logo `widthShare` of the frame width.
    public static func logoScale(logo: LogoInfo, frameWidth: Int, frameHeight: Int, widthShare: Double) -> Double {
        let fit = min(Double(frameWidth) / Double(logo.width), Double(frameHeight) / Double(logo.height))
        let fittedWidth = Double(logo.width) * fit
        return widthShare * Double(frameWidth) / fittedWidth
    }
}
