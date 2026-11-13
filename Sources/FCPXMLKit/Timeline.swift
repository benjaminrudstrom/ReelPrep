import Foundation

/// A video format resource (`<format>`).
public struct FCPFormat: Hashable, Sendable {
    public var name: String?
    public var frameDuration: RationalTime?
    public var width: Int
    public var height: Int
    public var colorSpace: String?

    public init(name: String? = nil, frameDuration: RationalTime?, width: Int, height: Int, colorSpace: String? = nil) {
        self.name = name
        self.frameDuration = frameDuration
        self.width = width
        self.height = height
        self.colorSpace = colorSpace
    }

    /// The reel project: 1080×1920 vertical, 29.97 fps, Rec. 709.
    public static let reel2997 = FCPFormat(name: "FFVideoFormat1080x1920p2997", frameDuration: .fd29_97,
                                           width: 1080, height: 1920, colorSpace: "1-1-1 (Rec. 709)")
}

/// A media file referenced in place (`<asset>` with one `<media-rep>`).
public struct FCPAsset: Sendable {
    public enum Kind: Sendable {
        case video(FCPFormat, hasAudio: Bool, audioChannels: Int?, audioRate: Int?)
        case audio(channels: Int, rate: Int)
        case still(FCPFormat)
    }

    public var name: String
    public var url: URL
    /// Asset start in its own time (the file's timecode origin, 0 when it has none).
    public var start: RationalTime
    public var duration: RationalTime
    public var kind: Kind

    public init(name: String, url: URL, start: RationalTime = .zero, duration: RationalTime, kind: Kind) {
        self.name = name
        self.url = url
        self.start = start
        self.duration = duration
        self.kind = kind
    }
}

/// Position, scale and rotation of a clip in the frame (`<adjust-transform>`).
/// Scale 1 is the clip filling the frame (conform "fill"); position is in FCP's units
/// (percent of frame height, origin at the centre, y up); rotation in degrees, counter-clockwise.
/// `scaleEnd`, when set, animates the scale from `scale` at the clip's first frame to `scaleEnd` at its end
/// (a slow push in or pull out, written as keyframes).
public struct FCPTransform: Hashable, Sendable {
    public var positionX: Double
    public var positionY: Double
    public var scale: Double
    public var rotation: Double
    public var scaleEnd: Double?

    public init(positionX: Double = 0, positionY: Double = 0, scale: Double = 1, rotation: Double = 0, scaleEnd: Double? = nil) {
        self.positionX = positionX
        self.positionY = positionY
        self.scale = scale
        self.rotation = rotation
        self.scaleEnd = scaleEnd
    }

    public static let identity = FCPTransform()
}

public extension FCPSpineClip {
    /// An empty slot of `duration` on the timeline.
    static func gap(duration: RationalTime, name: String = "Empty") -> FCPSpineClip {
        var c = FCPSpineClip(assetIndex: -1, name: name, duration: duration, sourceIn: .zero, stabilize: false)
        c.isGap = true
        return c
    }
}

/// One cut in the primary storyline.
public struct FCPSpineClip: Sendable {
    public var assetIndex: Int
    public var name: String
    /// Length on the timeline.
    public var duration: RationalTime
    /// In-point in the asset's own time (asset.start ... asset.start + asset.duration).
    public var sourceIn: RationalTime
    /// Playback speed: 1 = normal, 1/2 = 50 % slow motion (written as a `<timeMap>`).
    public var speed: RationalTime
    public var transform: FCPTransform
    public var stabilize: Bool
    /// Clip audio level; nil keeps it as recorded.
    public var volumeDB: Double?
    /// An empty slot: written as a `<gap>` (no asset; `assetIndex`, source and transform unused).
    public var isGap = false

    public init(assetIndex: Int, name: String, duration: RationalTime, sourceIn: RationalTime,
                speed: RationalTime = RationalTime(1), transform: FCPTransform = .identity,
                stabilize: Bool = true, volumeDB: Double? = nil) {
        self.assetIndex = assetIndex
        self.name = name
        self.duration = duration
        self.sourceIn = sourceIn
        self.speed = speed
        self.transform = transform
        self.stabilize = stabilize
        self.volumeDB = volumeDB
    }
}

/// A still (the logo) connected above the video.
public struct FCPOverlay: Sendable {
    public var assetIndex: Int
    public var name: String
    /// Timeline position and length.
    public var start: RationalTime
    public var duration: RationalTime
    public var transform: FCPTransform

    public init(assetIndex: Int, name: String, start: RationalTime, duration: RationalTime, transform: FCPTransform) {
        self.assetIndex = assetIndex
        self.name = name
        self.start = start
        self.duration = duration
        self.transform = transform
    }
}

public struct FCPMarker: Sendable {
    /// Timeline position.
    public var time: RationalTime
    public var name: String

    public init(time: RationalTime, name: String) {
        self.time = time
        self.name = name
    }
}

/// The song, on its own lane below the video, from the first frame, with the beat markers.
public struct FCPMusic: Sendable {
    public var assetIndex: Int
    public var name: String
    /// Where in the song the timeline's first frame is.
    public var sourceIn: RationalTime
    public var duration: RationalTime
    public var markers: [FCPMarker]

    public init(assetIndex: Int, name: String, sourceIn: RationalTime, duration: RationalTime, markers: [FCPMarker]) {
        self.assetIndex = assetIndex
        self.name = name
        self.sourceIn = sourceIn
        self.duration = duration
        self.markers = markers
    }
}

/// Everything one reel project needs; `FCPXMLWriter` turns it into a document.
public struct FCPTimeline: Sendable {
    public var eventName: String
    public var projectName: String
    public var format: FCPFormat
    public var assets: [FCPAsset]
    public var clips: [FCPSpineClip]
    public var overlays: [FCPOverlay]
    public var music: FCPMusic?
    /// The Final Cut library to import into (`<library location>`); nil lets Final Cut ask.
    public var libraryLocation: URL?

    public init(eventName: String, projectName: String, format: FCPFormat = .reel2997, assets: [FCPAsset],
                clips: [FCPSpineClip], overlays: [FCPOverlay] = [], music: FCPMusic? = nil) {
        self.eventName = eventName
        self.projectName = projectName
        self.format = format
        self.assets = assets
        self.clips = clips
        self.overlays = overlays
        self.music = music
    }

    public var duration: RationalTime { clips.reduce(.zero) { $0 + $1.duration } }
}
