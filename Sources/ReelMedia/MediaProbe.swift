import AVFoundation
import CoreMedia
import Foundation
import ImageIO
import FCPXMLKit
import ReelCore

public enum MediaError: Error, CustomStringConvertible {
    case noVideoTrack(String), noAudioTrack(String), unreadableImage(String), unsupported(String)

    public var description: String {
        switch self {
        case .noVideoTrack(let s): return "\(s) has no video track."
        case .noAudioTrack(let s): return "\(s) has no audio track."
        case .unreadableImage(let s): return "\(s) can't be read as an image."
        case .unsupported(let s): return s
        }
    }
}

public enum MediaKind: Sendable { case video, audio, logo }

public enum MediaTypes {
    public static let video: Set<String> = ["mov", "mp4", "m4v"]
    public static let audio: Set<String> = ["mp3", "m4a", "wav", "aif", "aiff", "aac", "caf"]
    public static let logo: Set<String> = ["png"]

    public static func kind(of url: URL) -> MediaKind? {
        let ext = url.pathExtension.lowercased()
        if video.contains(ext) { return .video }
        if audio.contains(ext) { return .audio }
        if logo.contains(ext) { return .logo }
        return nil
    }
}

public enum MediaProbe {
    // MARK: Video

    public static func clip(_ url: URL) async throws -> ClipInfo {
        let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        let name = url.deletingPathExtension().lastPathComponent
        guard let v = try await asset.loadTracks(withMediaType: .video).first else { throw MediaError.noVideoTrack(url.lastPathComponent) }
        let (natural, transform, nominal, range, descs) = try await v.load(.naturalSize, .preferredTransform,
                                                                           .nominalFrameRate, .timeRange, .formatDescriptions)
        let shown = natural.applying(transform)
        let fd = standardFrameDuration(fps: Double(nominal))
        let duration = rational(range.duration)

        let audio = try await asset.loadTracks(withMediaType: .audio).first
        var channels: Int?, rate: Int?
        if let a = audio, let d = try await a.load(.formatDescriptions).first,
           let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(d)?.pointee {
            channels = Int(asbd.mChannelsPerFrame)
            rate = Int(asbd.mSampleRate)
        }

        let meta = try await asset.load(.metadata)
        var make = await string(meta, .quickTimeMetadataMake)
        if make == nil { make = await string(meta, .commonIdentifierMake) }
        var model = await string(meta, .quickTimeMetadataModel)
        if model == nil { model = await string(meta, .commonIdentifierModel) }
        let device = classify(make: make, model: model, fileName: url.lastPathComponent)

        var date: Date?
        if let s = await string(meta, .quickTimeMetadataCreationDate) { date = parseDate(s) }
        if date == nil, let item = try await asset.load(.creationDate) { date = try? await item.load(.dateValue) }
        if date == nil { date = (try? url.resourceValues(forKeys: [.creationDateKey]))?.creationDate }

        return ClipInfo(url: url, name: name, start: try await timecodeStart(asset), duration: duration,
                        frameDuration: fd, fps: Double(nominal),
                        width: Int(abs(shown.width).rounded()), height: Int(abs(shown.height).rounded()),
                        colorSpace: descs.first.flatMap(colorSpace), captureDate: date, device: device,
                        deviceModel: model, hasAudio: audio != nil, audioChannels: channels, audioRate: rate)
    }

    /// The file's timecode origin (first sample of a tmcd track), or 0.
    static func timecodeStart(_ asset: AVURLAsset) async throws -> RationalTime {
        guard let tc = try await asset.loadTracks(withMediaType: .timecode).first,
              let desc = try await tc.load(.formatDescriptions).first,
              CMFormatDescriptionGetMediaSubType(desc) == kCMTimeCodeFormatType_TimeCode32 else { return .zero }
        let reader = try AVAssetReader(asset: asset)
        let out = AVAssetReaderTrackOutput(track: tc, outputSettings: nil)
        guard reader.canAdd(out) else { return .zero }
        reader.add(out)
        guard reader.startReading(), let sample = out.copyNextSampleBuffer(),
              let block = CMSampleBufferGetDataBuffer(sample) else { return .zero }
        var raw: Int32 = 0
        guard CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: 4, destination: &raw) == noErr else { return .zero }
        reader.cancelReading()
        let frameNumber = Int64(Int32(bigEndian: raw))
        let frameDur = CMTimeCodeFormatDescriptionGetFrameDuration(desc)
        guard frameNumber > 0, frameDur.timescale > 0 else { return .zero }
        return rational(frameDur) * frameNumber
    }

    static func string(_ items: [AVMetadataItem], _ id: AVMetadataIdentifier) async -> String? {
        guard let item = AVMetadataItem.metadataItems(from: items, filteredByIdentifier: id).first else { return nil }
        return try? await item.load(.stringValue)
    }

    static func parseDate(_ s: String) -> Date? {
        let f = ISO8601DateFormatter()
        for opts: ISO8601DateFormatter.Options in [[.withInternetDateTime], [.withInternetDateTime, .withFractionalSeconds]] {
            f.formatOptions = opts
            if let d = f.date(from: s) { return d }
        }
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        for p in ["yyyy-MM-dd'T'HH:mm:ssZ", "yyyy-MM-dd'T'HH:mm:ss.SSSZ", "yyyy-MM-dd HH:mm:ss"] {
            df.dateFormat = p
            if let d = df.date(from: s) { return d }
        }
        return nil
    }

    static func classify(make: String?, model: String?, fileName: String) -> SourceDevice {
        let m = ((make ?? "") + " " + (model ?? "")).lowercased()
        if m.contains("apple") || m.contains("iphone") { return .iPhone }
        if m.contains("canon") { return .canon }
        if m.contains("dji") { return .dji }
        let f = fileName.uppercased()
        if f.hasPrefix("DJI_") { return .dji }
        if f.hasPrefix("MVI_") || f.hasPrefix("_MG_") { return .canon }
        if f.hasPrefix("IMG_") { return .iPhone }
        return .other
    }

    /// FCPXML colour space string from the video's colour tags.
    static func colorSpace(_ desc: CMFormatDescription) -> String? {
        let ext = CMFormatDescriptionGetExtensions(desc) as? [String: Any] ?? [:]
        let prim = ext[kCMFormatDescriptionExtension_ColorPrimaries as String] as? String
        let tf = ext[kCMFormatDescriptionExtension_TransferFunction as String] as? String
        let is2020 = prim == (kCMFormatDescriptionColorPrimaries_ITU_R_2020 as String)
        if is2020 && tf == (kCMFormatDescriptionTransferFunction_ITU_R_2100_HLG as String) { return "9-18-9 (Rec. 2020 HLG)" }
        if is2020 && tf == (kCMFormatDescriptionTransferFunction_SMPTE_ST_2084_PQ as String) { return "9-16-9 (Rec. 2020 PQ)" }
        if is2020 { return "9-1-9 (Rec. 2020)" }
        if prim == (kCMFormatDescriptionColorPrimaries_ITU_R_709_2 as String) { return "1-1-1 (Rec. 709)" }
        return nil
    }

    /// Exact frame duration for the usual rates (iPhones report e.g. 29.98 or 59.96).
    public static func standardFrameDuration(fps: Double) -> RationalTime {
        let table: [(Double, RationalTime)] = [
            (23.976, .fd23_976), (24, .fd24), (25, .fd25), (29.97, .fd29_97), (30, .fd30), (50, .fd50),
            (59.94, .fd59_94), (60, .fd60), (119.88, .fd119_88), (120, .fd120),
        ]
        let best = table.min { abs($0.0 - fps) < abs($1.0 - fps) }!
        if abs(best.0 - fps) < 0.02 { return best.1 }
        // Between e.g. 29.97 and 30: iPhones at "30" are 30; anything off-grid goes to the nearest one.
        return best.1
    }

    static func rational(_ t: CMTime) -> RationalTime { RationalTime(t.value, Int64(t.timescale)) }

    // MARK: Song

    public static func song(_ url: URL) async throws -> SongInfo {
        let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        guard let a = try await asset.loadTracks(withMediaType: .audio).first else { throw MediaError.noAudioTrack(url.lastPathComponent) }
        let duration = try await asset.load(.duration)
        var channels = 2, rate = 44100
        if let d = try await a.load(.formatDescriptions).first,
           let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(d)?.pointee {
            channels = Int(asbd.mChannelsPerFrame)
            rate = Int(asbd.mSampleRate)
        }
        return SongInfo(url: url, name: url.deletingPathExtension().lastPathComponent, duration: rational(duration),
                        channels: channels, sampleRate: rate)
    }

    // MARK: Logo

    public static func logo(_ url: URL) throws -> LogoInfo {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? Int, let h = props[kCGImagePropertyPixelHeight] as? Int
        else { throw MediaError.unreadableImage(url.lastPathComponent) }
        return LogoInfo(url: url, name: url.deletingPathExtension().lastPathComponent, width: w, height: h)
    }
}
