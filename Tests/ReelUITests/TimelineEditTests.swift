import Foundation
import Testing
import FCPXMLKit
import ReelCore
@testable import ReelUI

@MainActor @Suite struct TimelineEditTests {
    func clip(_ n: String) -> ClipInfo {
        ClipInfo(url: URL(fileURLWithPath: "/tmp/\(n).mov"), name: n, duration: RationalTime(10), frameDuration: .fd30,
                 fps: 30, width: 1920, height: 1080)
    }

    @Test func insertMovesCutsAlongIntoTheNextEmptySlotAndUndoes() {
        let p = ReelProject()
        let a = clip("A"), b = clip("B"), c = clip("C"), d = clip("D"), gap = ClipInfo.placeholder()
        p.setClipsForTesting([a, b, gap, c, d], excluded: [d.url])
        p.insert(d.url, before: b.url)
        // D goes in before B; B moves along into the empty slot, so C stays where it was.
        #expect(p.clips.map(\.name) == ["A", "D", "B", "C"])
        #expect(!p.excluded.contains(d.url))
        #expect(p.beats.canUndo)
        p.undo()
        #expect(p.clips.map(\.name) == ["A", "B", "Empty", "C", "D"])
        #expect(p.excluded == [d.url])
        p.redo()
        #expect(p.clips.map(\.name) == ["A", "D", "B", "C"])
    }

    @Test func insertWithoutAnEmptySlotPushesTheRestAlong() {
        let p = ReelProject()
        let a = clip("A"), b = clip("B"), c = clip("C"), d = clip("D")
        p.setClipsForTesting([a, b, c, d], excluded: [d.url])
        p.insert(d.url, before: b.url)
        #expect(p.clips.map(\.name) == ["A", "D", "B", "C"])
    }

    @Test func framingAndBeatEditsShareOneHistory() {
        let p = ReelProject()
        let a = clip("A")
        p.setClipsForTesting([a])
        p.reframes[a.url] = Reframe(zoom: 1.5)
        p.undo()
        #expect(p.reframes[a.url] == nil)
        p.beats.restore(BeatList([1, 2], duration: 10))
        p.clearUndo()   // as after loading a song
        p.beats.beats.add(at: 3)
        #expect(p.beats.canUndo)
        p.beats.undo()   // ⌘Z in the beat editor goes to the project's history
        #expect(p.beats.beats.times == [1, 2])
    }
}
