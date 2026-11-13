import Foundation
import FCPXMLKit
import ReelCore

/// Writing a reel for Final Cut Pro, Premiere Pro or DaVinci Resolve, shared by the app and the CLI.
public enum ReelExporter {
    public enum ExportError: Error, CustomStringConvertible {
        case invalid(dtd: String, message: String, writtenTo: URL)
        public var description: String {
            switch self {
            case let .invalid(dtd, message, url):
                return "The FCPXML doesn't match \(dtd): \(message)\nWritten for inspection to \(url.path)"
            }
        }
    }

    /// Hands files with "%" in their names to Final Cut as clean-named links (it freezes on "%").
    public static func prepareMedia(clips: inout [ClipInfo], song: inout SongInfo, logo: inout LogoInfo?) throws -> [String] {
        var notes: [String] = []
        for i in clips.indices where MediaLinks.needsLink(clips[i].url) { clips[i].url = try MediaLinks.fcpURL(for: clips[i].url) }
        if MediaLinks.needsLink(song.url) {
            song.url = try MediaLinks.fcpURL(for: song.url)
            song.name = song.url.deletingPathExtension().lastPathComponent
            notes.append("Song handed to Final Cut as \(song.url.lastPathComponent) (a link: its name had \"%\" in it)")
        }
        if var l = logo, MediaLinks.needsLink(l.url) {
            l.url = try MediaLinks.fcpURL(for: l.url)
            l.name = l.url.deletingPathExtension().lastPathComponent
            logo = l
        }
        return notes
    }

    /// The Final Cut library used most recently (Movies, Pictures, Spotlight; backups left out): the one whose
    /// library or event database Final Cut wrote last. (The bundle folder's own date changes on mere opening.)
    public static func mostRecentLibrary() -> URL? {
        FCPBeatGrid.findLibraries().max { lastUsed($0) < lastUsed($1) }
    }

    static func lastUsed(_ library: URL) -> Date {
        func date(_ u: URL) -> Date { (try? u.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast }
        var d = date(library.appendingPathComponent("CurrentVersion.flexolibrary"))
        for e in FCPBeatGrid.events(in: library) { d = max(d, date(e.appendingPathComponent("CurrentVersion.fcpevent"))) }
        return d
    }

    /// Validates against Final Cut's DTD (when installed) and writes. Returns the DTD's name, or nil when
    /// Final Cut isn't installed. On a mismatch, writes `<name>.invalid.fcpxml` and throws.
    @discardableResult
    public static func write(_ timeline: FCPTimeline, to url: URL) throws -> String? {
        let xml = try FCPXMLWriter.document(for: timeline)
        var dtdName: String?
        if let dtd = FCPXMLValidator.dtdURL() {
            do { try FCPXMLValidator.validate(xml, dtd: dtd) } catch {
                let bad = url.deletingPathExtension().appendingPathExtension("invalid.fcpxml")
                try xml.write(to: bad, atomically: true, encoding: .utf8)
                throw ExportError.invalid(dtd: dtd.lastPathComponent, message: error.localizedDescription, writtenTo: bad)
            }
            dtdName = dtd.lastPathComponent
        }
        try xml.write(to: url, atomically: true, encoding: .utf8)
        return dtdName
    }

    public static func openInFinalCut(_ url: URL) throws {
        try runOpen(["-a", "Final Cut Pro", url.path])
    }

    /// Writes the reel for `editor`: the FCPXML (checked against Final Cut's DTD) or the Final Cut Pro 7 XML
    /// (checked to be well-formed; there is no DTD for it). Returns the DTD's name for the FCPXML, else nil.
    @discardableResult
    public static func write(_ timeline: FCPTimeline, to url: URL, for editor: Editor) throws -> String? {
        if editor == .finalCut { return try write(timeline, to: url) }
        let xml = try editor.document(for: timeline)
        _ = try XMLDocument(xmlString: xml)
        try xml.write(to: url, atomically: true, encoding: .utf8)
        return nil
    }

    /// Hands the file to the editor. Final Cut and Premiere import it on opening; Resolve is started and the file
    /// shown in the Finder, to import with File > Import > Timeline. Without the editor installed, the file is shown
    /// in the Finder. Returns what happened, for the message after export.
    @discardableResult
    public static func open(_ url: URL, in editor: Editor) throws -> String {
        guard let app = editor.installedApp else {
            try runOpen(["-R", url.path])
            return "\(editor.name) isn't installed here: the file is shown in the Finder"
        }
        if editor.opensFile {
            try runOpen(["-a", app.path, url.path])
            return "sent it to \(editor.name)"
        }
        try runOpen(["-a", app.path])
        try runOpen(["-R", url.path])
        return "started \(editor.name): import it with File > Import > Timeline"
    }

    static func runOpen(_ arguments: [String]) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        p.arguments = arguments
        try p.run()
        p.waitUntilExit()
    }
}
