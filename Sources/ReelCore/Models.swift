import Foundation
import FCPXMLKit

public enum SourceDevice: String, Sendable {
    case iPhone, canon = "Canon", dji = "DJI drone", other = "other"
}

/// What ReelPrep needs to know about a video clip (read by ReelMedia).
public struct ClipInfo: Sendable {
    public var url: URL
    public var name: String
    /// Timecode origin of the file (0 when it has none) and video length, in file time.
    public var start: RationalTime
    public var duration: RationalTime
    public var frameDuration: RationalTime
    public var fps: Double
    /// Displayed size (after the file's rotation), and the encoded size.
    public var width: Int
    public var height: Int
    public var colorSpace: String?
    public var captureDate: Date?
    public var device: SourceDevice
    public var deviceModel: String?
    public var hasAudio: Bool
    public var audioChannels: Int?
    public var audioRate: Int?

    public init(url: URL, name: String, start: RationalTime = .zero, duration: RationalTime, frameDuration: RationalTime,
                fps: Double, width: Int, height: Int, colorSpace: String? = nil, captureDate: Date? = nil,
                device: SourceDevice = .other, deviceModel: String? = nil, hasAudio: Bool = false,
                audioChannels: Int? = nil, audioRate: Int? = nil) {
        self.url = url
        self.name = name
        self.start = start
        self.duration = duration
        self.frameDuration = frameDuration
        self.fps = fps
        self.width = width
        self.height = height
        self.colorSpace = colorSpace
        self.captureDate = captureDate
        self.device = device
        self.deviceModel = deviceModel
        self.hasAudio = hasAudio
        self.audioChannels = audioChannels
        self.audioRate = audioRate
    }

    public var isPortrait: Bool { height > width }

    /// An empty slot in the reel, kept in the clip order like a clip (URL scheme "reelprep-gap").
    public var isPlaceholder: Bool { url.scheme == ClipInfo.placeholderScheme }
    public static let placeholderScheme = "reelprep-gap"

    public static func placeholder() -> ClipInfo {
        ClipInfo(url: URL(string: "\(placeholderScheme):\(UUID().uuidString)")!, name: "Empty", duration: RationalTime(3600),
                 frameDuration: .fd30, fps: 30, width: 1080, height: 1920)
    }

    /// 50 % slow motion for high frame rate clips (50/59.94/60 fps and up) on the 29.97 timeline.
    public var speed: RationalTime { fps >= 47 ? RationalTime(1, 2) : RationalTime(1) }

    public var format: FCPFormat {
        FCPFormat(name: nil, frameDuration: frameDuration, width: width, height: height, colorSpace: colorSpace)
    }
}

public struct SongInfo: Sendable {
    public var url: URL
    public var name: String
    public var duration: RationalTime
    public var channels: Int
    public var sampleRate: Int

    public init(url: URL, name: String, duration: RationalTime, channels: Int, sampleRate: Int) {
        self.url = url
        self.name = name
        self.duration = duration
        self.channels = channels
        self.sampleRate = sampleRate
    }
}

public struct LogoInfo: Sendable {
    public var url: URL
    public var name: String
    public var width: Int
    public var height: Int

    public init(url: URL, name: String, width: Int, height: Int) {
        self.url = url
        self.name = name
        self.width = width
        self.height = height
    }
}

/// Clip order: capture time, then name.
public func sortedByCaptureTime(_ clips: [ClipInfo]) -> [ClipInfo] {
    clips.sorted { a, b in
        switch (a.captureDate, b.captureDate) {
        case let (x?, y?) where x != y: return x < y
        case (_?, nil): return true
        case (nil, _?): return false
        default: return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
    }
}
