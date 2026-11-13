import CryptoKit
import Foundation

/// Where a song's beats came from.
public enum BeatSource: String, Codable, Sendable {
    case corrected = "corrected by hand"
    case finalCut = "Final Cut Pro's beat detection"
    case reelPrep = "ReelPrep's beat detection"
    case file = "a beats file"
}

/// Beats corrected by hand in the beat editor, saved per song in
/// ~/Library/Application Support/ReelPrep/Beats/<content hash>.json, so renamed, copied or linked
/// copies of the same song find them, and the CLI and the app share them.
public enum BeatStore {
    public struct Entry: Codable, Sendable {
        public var songName: String
        public var beats: [Double]
        public var saved: Date
        /// What the hand correction started from.
        public var basedOn: BeatSource
    }

    public static var folder: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/ReelPrep/Beats", isDirectory: true)
    }

    public static func key(for song: URL) throws -> String {
        let h = try SHA256.hash(data: Data(contentsOf: song, options: .alwaysMapped))
        return h.prefix(16).map { String(format: "%02x", $0) }.joined()
    }

    public static func load(for song: URL, folder: URL = BeatStore.folder) -> Entry? {
        guard let k = try? key(for: song),
              let data = try? Data(contentsOf: folder.appendingPathComponent(k + ".json")) else { return nil }
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return try? d.decode(Entry.self, from: data)
    }

    public static func save(_ beats: [Double], for song: URL, basedOn: BeatSource, folder: URL = BeatStore.folder) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        let entry = Entry(songName: song.lastPathComponent, beats: beats.map { ($0 * 10000).rounded() / 10000 },
                          saved: Date(), basedOn: basedOn)
        try e.encode(entry).write(to: folder.appendingPathComponent(try key(for: song) + ".json"), options: .atomic)
    }

    /// Forget the hand correction (back to detected beats).
    public static func remove(for song: URL, folder: URL = BeatStore.folder) throws {
        let url = folder.appendingPathComponent(try key(for: song) + ".json")
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
    }

    /// The beats to use for a song: hand-corrected, else Final Cut's, else ReelPrep's own detection.
    public static func beats(for song: URL, detect: Bool = false) throws -> (beats: [Double], source: BeatSource, bpm: Double?) {
        if !detect {
            if let e = load(for: song) { return (e.beats, .corrected, nil) }
            if let g = FCPBeatGrid.find(for: song) { return (g.beats, .finalCut, g.bpm) }
        }
        let a = try BeatDetector.analyze(url: song)
        return (a.beats, .reelPrep, a.bpm)
    }

    /// The detected beats, ignoring any hand correction (what "Revert" goes back to).
    public static func detected(for song: URL) throws -> (beats: [Double], source: BeatSource) {
        if let g = FCPBeatGrid.find(for: song) { return (g.beats, .finalCut) }
        return (try BeatDetector.analyze(url: song).beats, .reelPrep)
    }
}
