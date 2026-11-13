import Foundation

/// Beats that Final Cut Pro detected for a song (its Beat Grid), read from a Final Cut library.
///
/// Read only: library files are read as bytes, the event database is never opened as a database,
/// nothing in the library is written. Layout (Final Cut Pro 12.4, seen 2026-11-10):
/// - each event has `Original Media/<name>`: a symlink to a file used in place, or a copy;
/// - the event's `CurrentVersion.fcpevent` stores `Original Media/<name>` next to the media's 32-hex id;
/// - `__.fcpdata.apple.com/media_metadata/<id>/<id>_beatDetectionResults.dat` is a keyed archive of
///   timing entries {time, timescale, type}: type 1 = beat, 2 = bar, 4 = section, 8 = tempo (value = BPM).
public struct FCPBeatGrid: Sendable {
    public var beats: [Double]
    public var bars: [Double]
    public var bpm: Double?
    public var library: URL
    public var resultsFile: URL

    public static func find(for song: URL, libraries: [URL]? = nil) -> FCPBeatGrid? {
        guard let target = FileIdentity(song) else { return nil }
        var found: [FCPBeatGrid] = []
        for lib in libraries ?? findLibraries() {
            for event in events(in: lib) {
                for name in matchingNames(in: event, target: target, songName: song.lastPathComponent) {
                    for id in mediaIDs(event: event, name: name) {
                        let file = lib.appendingPathComponent("__.fcpdata.apple.com/media_metadata/\(id)/\(id)_beatDetectionResults.dat")
                        if var grid = decode(file) {
                            grid.library = lib
                            found.append(grid)
                        }
                    }
                }
            }
        }
        // Newest analysis wins.
        func date(_ g: FCPBeatGrid) -> Date {
            (try? g.resultsFile.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
        }
        return found.max { date($0) < date($1) }
    }

    /// Final Cut libraries on this Mac, from Spotlight; backups left out. Found once per run.
    /// No folder walking: it takes minutes in a photo archive, and in the app it sets off macOS's privacy
    /// prompts for Movies and other folders (seen 2026-11-10).
    public static func findLibraries() -> [URL] {
        if let cached = LibraryCache.shared.urls { return cached }
        var paths = Set<String>()
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/mdfind")
        p.arguments = ["kMDItemFSName == '*.fcpbundle'"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        if (try? p.run()) != nil {
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            String(decoding: data, as: UTF8.self).split(separator: "\n").forEach { paths.insert(String($0)) }
        }
        let found = paths.filter { !$0.contains("Final Cut Backups") }.sorted().map { URL(fileURLWithPath: $0) }
        LibraryCache.shared.urls = found
        return found
    }

    final class LibraryCache: @unchecked Sendable {
        static let shared = LibraryCache()
        private let lock = NSLock()
        private var _urls: [URL]?
        var urls: [URL]? {
            get { lock.lock(); defer { lock.unlock() }; return _urls }
            set { lock.lock(); _urls = newValue; lock.unlock() }
        }
    }

    static func events(in library: URL) -> [URL] {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(at: library, includingPropertiesForKeys: nil) else { return [] }
        return items.filter { fm.fileExists(atPath: $0.appendingPathComponent("CurrentVersion.fcpevent").path) }
    }

    /// Names in the event's Original Media that are the song: the same file (symlink or hard link to it),
    /// or a copy with the same name and size.
    static func matchingNames(in event: URL, target: FileIdentity, songName: String) -> [String] {
        let dir = event.appendingPathComponent("Original Media")
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return [] }
        return names.filter { name in
            guard let id = FileIdentity(dir.appendingPathComponent(name)) else { return false }
            if id.sameFile(as: target) { return true }
            return id.size == target.size
                && name.precomposedStringWithCanonicalMapping == songName.precomposedStringWithCanonicalMapping
        }
    }

    /// The 32-hex media ids stored right after "Original Media/<name>" in the event database.
    static func mediaIDs(event: URL, name: String) -> [String] {
        guard let db = try? Data(contentsOf: event.appendingPathComponent("CurrentVersion.fcpevent"), options: .alwaysMapped)
        else { return [] }
        var ids: [String] = []
        let forms = Set([name, name.precomposedStringWithCanonicalMapping, name.decomposedStringWithCanonicalMapping])
        for form in forms {
            let needle = Data(("Original Media/" + form).utf8)
            var from = db.startIndex
            while let r = db.range(of: needle, in: from..<db.endIndex) {
                let window = db[r.upperBound..<min(db.endIndex, r.upperBound + 64)]
                if let id = firstHexID(in: window), !ids.contains(id) { ids.append(id) }
                from = r.upperBound
            }
        }
        return ids
    }

    static func firstHexID(in bytes: Data) -> String? {
        var run: [UInt8] = []
        for b in bytes {
            let hex = (b >= 0x30 && b <= 0x39) || (b >= 0x41 && b <= 0x46)
            if hex { run.append(b); if run.count == 32 { return String(decoding: run, as: UTF8.self) } } else { run = [] }
        }
        return nil
    }

    public static func decode(_ file: URL) -> FCPBeatGrid? {
        guard let data = try? Data(contentsOf: file),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let objects = plist["$objects"] as? [Any] else { return nil }
        var beats: [Double] = [], bars: [Double] = []
        var bpm: Double?
        for case let o as [String: Any] in objects {
            if let v = o["value"] as? Double, bpm == nil { bpm = v }
            guard let type = (o["type"] as? NSNumber)?.intValue, let time = (o["time"] as? NSNumber)?.doubleValue,
                  let scale = (o["timescale"] as? NSNumber)?.doubleValue, scale > 0 else { continue }
            if type == 1 { beats.append(time / scale) }
            if type == 2 { bars.append(time / scale) }
        }
        guard beats.count >= 2 else { return nil }
        return FCPBeatGrid(beats: beats.sorted(), bars: bars.sorted(), bpm: bpm, library: file, resultsFile: file)
    }
}

/// Device + inode (following symlinks), and size.
struct FileIdentity {
    let device: UInt64
    let inode: UInt64
    let size: UInt64

    init?(_ url: URL) {
        var st = stat()
        guard stat(url.path, &st) == 0 else { return nil }
        device = UInt64(st.st_dev)
        inode = UInt64(st.st_ino)
        size = UInt64(st.st_size)
    }

    func sameFile(as o: FileIdentity) -> Bool { device == o.device && inode == o.inode }
}
