import Foundation
import FCPXMLKit
import FCP7XMLKit

/// The editor the reel is finished in, and the file it gets.
public enum Editor: String, CaseIterable, Identifiable, Sendable {
    case finalCut, premiere, resolve

    public var id: String { rawValue }

    public var name: String {
        switch self {
        case .finalCut: return "Final Cut Pro"
        case .premiere: return "Premiere Pro"
        case .resolve: return "DaVinci Resolve"
        }
    }

    /// FCPXML for Final Cut; Final Cut Pro 7 XML for Premiere and Resolve (both import it).
    public var fileExtension: String { self == .finalCut ? "fcpxml" : "xml" }

    /// How the file gets into the editor, for the save panel and the message after export.
    public var importHint: String {
        switch self {
        case .finalCut: return "The project opens in Final Cut Pro, referencing your files where they are."
        case .premiere: return "The sequence opens in Premiere Pro, referencing your files where they are. Stabilization isn't in the file: add Warp Stabilizer there."
        case .resolve: return "Import it in DaVinci Resolve with File > Import > Timeline. Stabilization isn't in the file: add it there."
        }
    }

    /// Opening the file imports it in Final Cut and Premiere; Resolve only imports from its own menu.
    public var opensFile: Bool { self != .resolve }

    /// For the command line: "finalcut", "fcp", "premiere", "resolve" …
    public init?(argument: String) {
        switch argument.lowercased().replacingOccurrences(of: " ", with: "").replacingOccurrences(of: "-", with: "") {
        case "finalcut", "finalcutpro", "fcp", "fcpx": self = .finalCut
        case "premiere", "premierepro", "ppro": self = .premiere
        case "resolve", "davinci", "davinciresolve": self = .resolve
        default: return nil
        }
    }

    /// The installed app, newest first when there are several (Premiere installs one per year).
    public var installedApp: URL? { Editor.findApp(self, in: Editor.searchFolders) }

    static var searchFolders: [URL] {
        let fm = FileManager.default
        return [URL(fileURLWithPath: "/Applications"),
                fm.homeDirectoryForCurrentUser.appendingPathComponent("Applications")]
    }

    static func findApp(_ editor: Editor, in folders: [URL]) -> URL? {
        let fm = FileManager.default
        var found: [URL] = []
        for folder in folders {
            guard let items = try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) else { continue }
            for item in items {
                // Apps sit in /Applications or one folder down ("Adobe Premiere Pro 2025/…app", "DaVinci Resolve/…app").
                let candidates = item.pathExtension == "app" ? [item]
                    : ((try? fm.contentsOfDirectory(at: item, includingPropertiesForKeys: nil)) ?? []).filter { $0.pathExtension == "app" }
                found += candidates.filter { editor.matches($0.deletingPathExtension().lastPathComponent) }
            }
        }
        return found.max { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }

    func matches(_ appName: String) -> Bool {
        switch self {
        case .finalCut: return appName == "Final Cut Pro" || appName == "Final Cut Pro Trial"
        case .premiere: return appName.hasPrefix("Adobe Premiere Pro")
        case .resolve: return appName == "DaVinci Resolve" || appName == "DaVinci Resolve Studio"
        }
    }

    /// The document for this editor.
    public func document(for timeline: FCPTimeline) throws -> String {
        switch self {
        case .finalCut: return try FCPXMLWriter.document(for: timeline)
        case .premiere, .resolve: return try FCP7XMLWriter.document(for: timeline)
        }
    }
}
