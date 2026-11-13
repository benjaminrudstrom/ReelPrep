import Foundation
import Testing
@testable import ReelMedia

@Suite struct FCPBeatGridTests {
    /// A fake library: one event using `song` in place, with results in Final Cut's layout.
    static func makeLibrary(in dir: URL, song: URL, id: String, beats: [Int64], bpm: Double) throws -> URL {
        let fm = FileManager.default
        let lib = dir.appendingPathComponent("Test.fcpbundle")
        let event = lib.appendingPathComponent("Event")
        try fm.createDirectory(at: event.appendingPathComponent("Original Media"), withIntermediateDirectories: true)
        try fm.createSymbolicLink(at: event.appendingPathComponent("Original Media/\(song.lastPathComponent)"), withDestinationURL: song)
        var db = Data([0, 1, 2])
        db += Data("Z\u{5}Original Media/\(song.lastPathComponent)\u{0}\u{1}_. \(id)....".utf8)
        try db.write(to: event.appendingPathComponent("CurrentVersion.fcpevent"))
        var objects: [Any] = ["$null", ["value": bpm], ["time": 0, "timescale": 48000, "type": 8]]
        for b in beats { objects.append(["time": b, "timescale": 44100, "type": 1]) }
        objects.append(["time": 0, "timescale": 44100, "type": 2])
        let plist: [String: Any] = ["$archiver": "NSKeyedArchiver", "$version": 100000, "$objects": objects]
        let results = lib.appendingPathComponent("__.fcpdata.apple.com/media_metadata/\(id)")
        try fm.createDirectory(at: results, withIntermediateDirectories: true)
        try PropertyListSerialization.data(fromPropertyList: plist, format: .binary, options: 0)
            .write(to: results.appendingPathComponent("\(id)_beatDetectionResults.dat"))
        return lib
    }

    @Test func readsBeatsForTheSameFile() throws {
        let dir = try TestMedia.folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let song = dir.appendingPathComponent("song.mp3")
        try Data(repeating: 1, count: 1000).write(to: song)
        let id = "8A9840D89C73AF9DD2617EBA81AB78CB"
        let lib = try Self.makeLibrary(in: dir, song: song, id: id, beats: [0, 29812, 59577], bpm: 88.8)
        let grid = try #require(FCPBeatGrid.find(for: song, libraries: [lib]))
        #expect(grid.bpm == 88.8)
        #expect(grid.beats.count == 3)
        #expect(abs(grid.beats[1] - 0.676) < 0.001)
        #expect(grid.bars == [0])

        // A hard link to the song (as ReelPrep hands "%" names to Final Cut) is the same file.
        let link = dir.appendingPathComponent("link.mp3")
        try FileManager.default.linkItem(at: song, to: link)
        #expect(FCPBeatGrid.find(for: link, libraries: [lib]) != nil)

        // Another file is not.
        let other = dir.appendingPathComponent("other.mp3")
        try Data(repeating: 2, count: 999).write(to: other)
        #expect(FCPBeatGrid.find(for: other, libraries: [lib]) == nil)
    }

    @Test func findsHexIDAfterName() {
        #expect(FCPBeatGrid.firstHexID(in: Data("..._. 8A9840D89C73AF9DD2617EBA81AB78CB..".utf8)) == "8A9840D89C73AF9DD2617EBA81AB78CB")
        #expect(FCPBeatGrid.firstHexID(in: Data("abc 123".utf8)) == nil)
    }
}

@Suite struct MediaLinksTests {
    @Test func cleanNames() {
        #expect(MediaLinks.cleanName("ES_My%20Song%20%28Version%201%29.mp3") == "ES_My Song (Version 1).mp3")
        #expect(MediaLinks.cleanName("50%off.mp3") == "50_off.mp3")
        #expect(!MediaLinks.needsLink(URL(fileURLWithPath: "/a/b c.mp3")))
    }

    @Test func linksPercentNamesWithoutCopying() throws {
        let dir = try TestMedia.folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let src = dir.appendingPathComponent("ES_My%20Song.mp3")
        try Data(repeating: 7, count: 100).write(to: src)
        let links = dir.appendingPathComponent("Links")
        let a = try MediaLinks.fcpURL(for: src, folder: links)
        #expect(a.lastPathComponent == "ES_My Song.mp3")
        #expect(FileIdentity(a)!.sameFile(as: FileIdentity(src)!))
        #expect(try MediaLinks.fcpURL(for: src, folder: links) == a) // reused
        let plain = dir.appendingPathComponent("song.mp3")
        #expect(try MediaLinks.fcpURL(for: plain, folder: links) == plain)
    }
}
