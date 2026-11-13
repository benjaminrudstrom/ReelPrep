import AVFoundation
import CoreGraphics
import CryptoKit
import Foundation

/// Small H.264 copies of the clips for smooth scrubbing in the app (4K HEVC scrubs badly).
/// Kept in ~/Library/Caches/ReelPrep/Proxies, keyed by path, size and date, so they are made once.
/// Only for the app's preview: the FCPXML always points at the originals.
/// Proxy time 0 is the clip's start (its timecode origin, `ClipInfo.start`).
public enum Proxies {
    public static var folder: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Caches/ReelPrep/Proxies", isDirectory: true)
    }

    public static func url(for clip: URL, folder: URL = Proxies.folder) -> URL {
        let v = try? clip.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        let key = "\(clip.standardizedFileURL.path)|\(v?.fileSize ?? 0)|\(v?.contentModificationDate?.timeIntervalSince1970 ?? 0)"
        let h = SHA256.hash(data: Data(key.utf8)).prefix(16).map { String(format: "%02x", $0) }.joined()
        return folder.appendingPathComponent(h + ".mp4")
    }

    public static func exists(for clip: URL, folder: URL = Proxies.folder) -> Bool {
        FileManager.default.fileExists(atPath: url(for: clip, folder: folder).path)
    }

    /// Makes (or reuses) the proxy and returns its URL.
    public static func make(for clip: URL, folder: URL = Proxies.folder) async throws -> URL {
        let out = url(for: clip, folder: folder)
        if FileManager.default.fileExists(atPath: out.path) { return out }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let tmp = out.deletingPathExtension().appendingPathExtension("part.mp4")
        try? FileManager.default.removeItem(at: tmp)
        let asset = AVURLAsset(url: clip)
        guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPreset960x540) else {
            throw MediaError.unsupported("Can't make a preview copy of \(clip.lastPathComponent).")
        }
        session.outputURL = tmp
        session.outputFileType = .mp4
        session.shouldOptimizeForNetworkUse = false
        let box = SessionBox(session)
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            box.session.exportAsynchronously {
                if box.session.status == .completed { c.resume() } else {
                    c.resume(throwing: box.session.error ?? MediaError.unsupported("Preview copy of \(clip.lastPathComponent) failed."))
                }
            }
        }
        try FileManager.default.moveItem(at: tmp, to: out)
        return out
    }

    private final class SessionBox: @unchecked Sendable {
        let session: AVAssetExportSession
        init(_ s: AVAssetExportSession) { session = s }
    }
}

/// Evenly spaced thumbnails of a clip, for the filmstrip.
public enum Filmstrip {
    public static func images(of url: URL, count: Int, height: CGFloat = 120) async -> [CGImage] {
        let asset = AVURLAsset(url: url)
        guard let duration = try? await asset.load(.duration), duration.seconds > 0, count > 0 else { return [] }
        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        gen.maximumSize = CGSize(width: height * 2, height: height * 2)
        gen.requestedTimeToleranceBefore = CMTime(value: 1, timescale: 10)
        gen.requestedTimeToleranceAfter = CMTime(value: 1, timescale: 10)
        let times = (0..<count).map { i in
            CMTime(seconds: duration.seconds * (Double(i) + 0.5) / Double(count), preferredTimescale: 600)
        }
        var out: [CGImage?] = Array(repeating: nil, count: count)
        for await result in gen.images(for: times) {
            if let img = try? result.image, let i = times.firstIndex(of: result.requestedTime) { out[i] = img }
        }
        return out.compactMap { $0 }
    }
}
