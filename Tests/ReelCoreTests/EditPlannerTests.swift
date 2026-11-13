import Foundation
import Testing
import FCPXMLKit
@testable import ReelCore

@Suite struct EditPlannerTests {
    let fd = RationalTime.fd29_97
    /// 120 BPM, first beat at 0.5 s.
    let beats = (1...60).map { Double($0) * 0.5 }

    func clip(_ name: String, seconds: Int64, fps: Double = 30, date: TimeInterval = 0) -> ClipInfo {
        let fdc: RationalTime = fps >= 59 ? .fd59_94 : .fd30
        return ClipInfo(url: URL(fileURLWithPath: "/tmp/\(name).mov"), name: name, duration: RationalTime(seconds),
                        frameDuration: fdc, fps: fps, width: 1080, height: 1920, captureDate: Date(timeIntervalSince1970: date))
    }

    @Test func cutsEveryNBeats() {
        var s = PlanSettings(); s.beatsPerCut = 4
        let p = EditPlanner.plan(clips: [clip("a", seconds: 10), clip("b", seconds: 10), clip("c", seconds: 10)],
                                 beats: beats, songDuration: 30, settings: s)
        #expect(p.slots.count == 3)
        // Cuts on beats 4, 8, 12 = 2 s, 4 s, 6 s, snapped to 29.97 frames.
        #expect(p.slots.map(\.endFrame) == [60, 120, 180])
        #expect(p.slots.first?.beats == 4)
        #expect(p.introEndFrame == 60)
        #expect(p.outroStartFrame == 120)
        #expect(p.beatFrames.count == 12)
        #expect(p.warnings.isEmpty)
    }

    @Test func logoEdgesOnBeatsInsideCuts() {
        var s = PlanSettings(); s.beatsPerCut = 4; s.fixedCuts = true
        s.introBeats = 2     // beat 2 (1 s), inside the first cut
        s.outroBeats = 1     // one beat before the end, inside the last cut
        let p = EditPlanner.plan(clips: [clip("a", seconds: 10), clip("b", seconds: 10), clip("c", seconds: 10)],
                                 beats: beats, songDuration: 30, settings: s)
        #expect(p.introEndFrame == 30)
        #expect(p.outroStartFrame == 165)
    }

    @Test func centresTheSourceWindow() {
        let p = EditPlanner.plan(clips: [clip("a", seconds: 10)], beats: beats, songDuration: 30, settings: PlanSettings())
        // 60 frames of 1001/30000 = 2.002 s used of 10 s → in-point ≈ 3.999 s, on the 1/30 grid.
        let s = p.slots[0]
        #expect(s.sourceIn == RationalTime(119, 30))
        #expect(p.introEndFrame == 60 && p.outroStartFrame == nil)
    }

    @Test func slowMotionNeedsHalfTheSource() {
        // 1.5 s of 59.94 footage fills 3 s; a 4-beat (2 s) slot fits, needing 1.001 s of source.
        let p = EditPlanner.plan(clips: [clip("drone", seconds: 2, fps: 59.94)], beats: beats, songDuration: 30,
                                 settings: PlanSettings())
        #expect(p.slots[0].speed == RationalTime(1, 2))
        #expect(p.slots[0].endFrame == 60)
    }

    @Test func shortensSlotForShortClip() {
        // 1 s clip: fits 1 beat of a 4-beat slot.
        let p = EditPlanner.plan(clips: [clip("short", seconds: 1) , clip("b", seconds: 10)],
                                 beats: beats, songDuration: 30, settings: PlanSettings())
        #expect(p.slots[0].beats == 1) // 1 s clip: beat 1 at 0.5 s fits, beat 2 (1.001 s) doesn't
        #expect(p.slots[1].startFrame == p.slots[0].endFrame)
        #expect(p.slots[1].beats == 4)
        #expect(p.warnings.contains { $0.contains("Shortened short") })
    }

    @Test func skipsClipTooShortForOneBeat() {
        let tiny = ClipInfo(url: URL(fileURLWithPath: "/tmp/t.mov"), name: "tiny", duration: RationalTime(1, 5),
                            frameDuration: .fd30, fps: 30, width: 1080, height: 1920)
        let p = EditPlanner.plan(clips: [tiny, clip("b", seconds: 10)], beats: beats, songDuration: 30, settings: PlanSettings())
        #expect(p.slots.count == 1)
        #expect(p.slots[0].clipIndex == 1)
        #expect(p.warnings.contains { $0.contains("Skipped tiny") })
    }

    @Test func songLengthCapsTheReel() {
        let clips = (0..<20).map { clip("c\($0)", seconds: 10) }
        var s = PlanSettings(); s.maxLength = 7
        // Fitted: 2-beat (1 s) cuts, the shortest allowed; the 6.0–6.5 s leftover is too short for one.
        let p = EditPlanner.plan(clips: clips, beats: beats, songDuration: 30, settings: s)
        #expect(p.duration.seconds <= 7)
        #expect(p.slots.count == 6)
        #expect(p.slots.allSatisfy { $0.beats == 2 })
        #expect(p.slots.last?.endFrame == 180)
        #expect(p.warnings.contains { $0.contains("Not enough beats left") })
        // Fixed 4-beat cuts: 2, 4, 6 s.
        s.fixedCuts = true
        let f = EditPlanner.plan(clips: clips, beats: beats, songDuration: 30, settings: s)
        #expect(f.slots.map(\.endFrame) == [60, 120, 180])
    }

    @Test func fitsAllClipsIntoTheSong() {
        // 14 clips, 15 s song at 120 BPM (30 beats from 0.5 s): every clip gets 2 beats, about 1 s.
        let clips = (0..<14).map { clip("c\($0)", seconds: 10) }
        let p = EditPlanner.plan(clips: clips, beats: beats.filter { $0 <= 15 }, songDuration: 15.3, settings: PlanSettings())
        #expect(p.slots.count == 14)
        #expect(p.slots.allSatisfy { (2...3).contains($0.beats) })
        #expect(p.slots.allSatisfy { (RationalTime.fd29_97 * ($0.endFrame - $0.startFrame)).seconds >= 0.9 })
    }

    @Test func firstCutLastsTheMinimumFromFrameOne() {
        // First beat at 0.17 s: two beats from the first frame would be 0.67 s, so the first cut takes three.
        let early = (0..<30).map { 0.17 + Double($0) * 0.505 }
        let clips = (0..<14).map { clip("c\($0)", seconds: 10) }
        let p = EditPlanner.plan(clips: clips, beats: early, songDuration: 15.3, settings: PlanSettings())
        #expect(p.slots[0].beats == 3)
        #expect((RationalTime.fd29_97 * p.slots[0].endFrame).seconds >= 0.9)
    }

    @Test func songStartBeatShiftsBeats() {
        var s = PlanSettings(); s.songStartBeat = 3 // beat at 2.0 s
        let p = EditPlanner.plan(clips: [clip("a", seconds: 10)], beats: beats, songDuration: 30, settings: s)
        #expect(p.songInFrames == 60)
        #expect(p.beatFrames.first == 15)
    }

    @Test func introOutroBeatOverrides() {
        var s = PlanSettings(); s.introBeats = 2; s.outroBeats = 2
        let p = EditPlanner.plan(clips: [clip("a", seconds: 10), clip("b", seconds: 10), clip("c", seconds: 10)],
                                 beats: beats, songDuration: 30, settings: s)
        #expect(p.introEndFrame == 30)  // beat 2 = 1 s
        #expect(p.outroStartFrame == 150) // beat 10 = 5 s
    }

    @Test func userInPointsAreClampedToFit() {
        let clips = [clip("a", seconds: 10), clip("b", seconds: 10)]
        // a: start 1.5 s in; b: asks for 9.5 s, but a 2 s window only fits up to ~7.998 s.
        let p = EditPlanner.plan(clips: clips, beats: beats, songDuration: 30, settings: PlanSettings(),
                                 inPoints: [0: 1.5, 1: 9.5])
        #expect(p.slots[0].sourceIn == RationalTime(45, 30))
        let needed = RationalTime.fd29_97 * (p.slots[1].endFrame - p.slots[1].startFrame)
        #expect(p.slots[1].sourceIn + needed <= clips[1].duration)
        #expect(p.slots[1].sourceIn.seconds > 7.9)
    }

    @Test func draggedBeatCountsWinAndOthersReshare() {
        let clips = (0..<4).map { clip("c\($0)", seconds: 10) }
        // Cut 2 dragged to 6 beats (longer than the 4-beat maximum); the rest share what's left.
        let p = EditPlanner.plan(clips: clips, beats: beats.filter { $0 <= 8 }, songDuration: 8.4, settings: PlanSettings(),
                                 beatCounts: [1: 6])
        #expect(p.slots[1].beats == 6)
        #expect(p.slots[1].startFrame == p.slots[0].endFrame)
        #expect(p.beatGrid.count == 16)
    }

    @Test func ordersByCaptureTime() {
        let sorted = sortedByCaptureTime([clip("late", seconds: 1, date: 100), clip("early", seconds: 1, date: 5)])
        #expect(sorted.map(\.name) == ["early", "late"])
    }

    @Test func logoScaleIs66PercentOfWidth() {
        let wide = LogoInfo(url: URL(fileURLWithPath: "/tmp/l.png"), name: "l", width: 2000, height: 500)
        #expect(abs(ReelTimelineBuilder.logoScale(logo: wide, frameWidth: 1080, frameHeight: 1920, widthShare: 0.66) - 0.66) < 1e-9)
        // A tall logo is fitted by height first: 500×2000 fits to 480 wide, so scale = 712.8 / 480.
        let tall = LogoInfo(url: URL(fileURLWithPath: "/tmp/l.png"), name: "l", width: 500, height: 2000)
        #expect(abs(ReelTimelineBuilder.logoScale(logo: tall, frameWidth: 1080, frameHeight: 1920, widthShare: 0.66) - 1.485) < 1e-9)
    }

    @Test func timelineMutesClipsAndValidates() throws {
        let clips = [clip("a", seconds: 10), clip("b", seconds: 10, fps: 59.94)]
        let p = EditPlanner.plan(clips: clips, beats: beats, songDuration: 30, settings: PlanSettings())
        let song = SongInfo(url: URL(fileURLWithPath: "/tmp/s.m4a"), name: "s", duration: RationalTime(30), channels: 2, sampleRate: 44100)
        let logo = LogoInfo(url: URL(fileURLWithPath: "/tmp/l.png"), name: "l", width: 1000, height: 400)
        let t = ReelTimelineBuilder.timeline(plan: p, clips: clips, song: song, logo: logo, settings: PlanSettings(), projectName: "x")
        #expect(t.clips.allSatisfy { $0.volumeDB == -96 })
        #expect(t.overlays.count == 2)
        let xml = try FCPXMLWriter.document(for: t)
        if let dtd = FCPXMLValidator.dtdURL() { try FCPXMLValidator.validate(xml, dtd: dtd) }
    }
}
