import Foundation
import Testing
@testable import ReelMedia

@Suite struct BeatStoreTests {
    @Test func savesAndFindsByContent() throws {
        let dir = try TestMedia.folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let song = dir.appendingPathComponent("a.mp3")
        try Data(repeating: 3, count: 500).write(to: song)
        let store = dir.appendingPathComponent("Beats")
        #expect(BeatStore.load(for: song, folder: store) == nil)
        try BeatStore.save([0.5, 1.0], for: song, basedOn: .finalCut, folder: store)
        let copy = dir.appendingPathComponent("renamed copy.mp3")
        try FileManager.default.copyItem(at: song, to: copy)
        let e = try #require(BeatStore.load(for: copy, folder: store))
        #expect(e.beats == [0.5, 1.0] && e.basedOn == .finalCut && e.songName == "a.mp3")
        try BeatStore.remove(for: song, folder: store)
        #expect(BeatStore.load(for: song, folder: store) == nil)
    }
}

@Suite struct WaveformTests {
    @Test func peaksAndTapSnapping() {
        let s = TestMedia.clickSamples(bpm: 120, seconds: 4)   // clicks at 0.25, 0.75, …
        let w = Waveform(samples: s, sampleRate: 44100)
        #expect(abs(w.duration - 4) < 0.01)
        let (lo, hi) = w.range(from: 0.24, to: 0.30)
        #expect(hi > 0.3 && lo < -0.3)
        // A tap 50 ms late snaps back to the click (within ~one onset frame).
        #expect(abs(w.snapToAttack(1.30) - 1.25) < 0.025)
        // Nothing near: unchanged.
        #expect(w.snapToAttack(1.5, window: 0.02) == 1.5)
    }
}

@Suite struct EditorTests {
    @Test func commandLineNames() {
        #expect(Editor(argument: "finalcut") == .finalCut)
        #expect(Editor(argument: "Final Cut Pro") == .finalCut)
        #expect(Editor(argument: "premiere") == .premiere)
        #expect(Editor(argument: "DaVinci-Resolve") == .resolve)
        #expect(Editor(argument: "avid") == nil)
        #expect(Editor.premiere.fileExtension == "xml")
        #expect(Editor.finalCut.fileExtension == "fcpxml")
    }

    @Test func findsAppsOneFolderDownNewestFirst() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("editors-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        for path in ["Adobe Premiere Pro 2024/Adobe Premiere Pro 2024.app", "Adobe Premiere Pro 2025/Adobe Premiere Pro 2025.app",
                     "DaVinci Resolve/DaVinci Resolve.app", "Final Cut Pro.app", "Adobe Premiere Rush.app"] {
            try FileManager.default.createDirectory(at: root.appendingPathComponent(path), withIntermediateDirectories: true)
        }
        #expect(Editor.findApp(.premiere, in: [root])?.lastPathComponent == "Adobe Premiere Pro 2025.app")
        #expect(Editor.findApp(.resolve, in: [root])?.lastPathComponent == "DaVinci Resolve.app")
        #expect(Editor.findApp(.finalCut, in: [root])?.lastPathComponent == "Final Cut Pro.app")
        #expect(Editor.findApp(.premiere, in: [root.appendingPathComponent("nothing")]) == nil)
    }
}
