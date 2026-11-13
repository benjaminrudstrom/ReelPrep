import CryptoKit
import Foundation

/// Final Cut Pro freezes at "importing remote resources" when a referenced file name contains "%"
/// (seen 2026-11-10 with a downloaded song named like "ES_My%20Song%20%28Version%201%29.mp3"). For such files
/// ReelPrep gives Final Cut a hard link with a clean name in its own folder: the same file under a
/// second name, no extra space, the original untouched. Across volumes, where hard links can't go,
/// small files (songs, logos) are copied instead.
public enum MediaLinks {
    public static var folder: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/ReelPrep/Links", isDirectory: true)
    }

    public static func needsLink(_ url: URL) -> Bool { url.lastPathComponent.contains("%") }

    /// "ES_My%20Song.mp3" -> "ES_My Song.mp3"; any "%" left becomes "_".
    public static func cleanName(_ name: String) -> String {
        var n = name.removingPercentEncoding ?? name
        for bad in ["%", "/", ":"] { n = n.replacingOccurrences(of: bad, with: bad == "%" ? "_" : "-") }
        return n.isEmpty ? "media" : n
    }

    /// The URL to write into the FCPXML for `url`: itself, or a clean-named link to it.
    public static func fcpURL(for url: URL, copyLimit: UInt64 = 200_000_000, folder: URL = MediaLinks.folder) throws -> URL {
        guard needsLink(url) else { return url }
        let fm = FileManager.default
        let digest = SHA256.hash(data: Data(url.standardizedFileURL.path.utf8)).map { String(format: "%02x", $0) }.joined()
        let dir = folder.appendingPathComponent(String(digest.prefix(12)), isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let link = dir.appendingPathComponent(cleanName(url.lastPathComponent))
        if let a = FileIdentity(link), let b = FileIdentity(url), a.sameFile(as: b) { return link }
        if fm.fileExists(atPath: link.path) || (try? link.checkResourceIsReachable()) == true {
            try fm.removeItem(at: link) // stale: the original was replaced
        }
        do {
            try fm.linkItem(at: url, to: link)
        } catch {
            guard let size = FileIdentity(url)?.size, size <= copyLimit else {
                throw MediaError.unsupported("Final Cut Pro can't import \(url.lastPathComponent) (\"%\" in the name), and it is on another drive "
                                             + "and too large to copy. Rename it without \"%\".")
            }
            try fm.copyItem(at: url, to: link)
        }
        return link
    }
}
