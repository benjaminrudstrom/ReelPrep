import Foundation
import Testing
import FCPXMLKit
@testable import FCP7XMLKit

@Suite struct FCP7XMLWriterTests {
    /// Two cuts (a 59.94 fps landscape drone clip at 50 %, an upright iPhone clip), a gap-free reel with the logo on
    /// intro and outro and the song from 15 frames in with two beat markers.
    static func sample(scaleEnd: Double? = nil, gapFirst: Bool = false) -> FCPTimeline {
        let fd = RationalTime.fd29_97
        let v60 = FCPFormat(frameDuration: .fd59_94, width: 3840, height: 2160, colorSpace: "1-1-1 (Rec. 709)")
        let v30 = FCPFormat(frameDuration: .fd30, width: 1080, height: 1920)
        let assets = [
            FCPAsset(name: "DJI_0001", url: URL(fileURLWithPath: "/tmp/reel & co/DJI_0001.MP4"), start: RationalTime(3600),
                     duration: RationalTime(10), kind: .video(v60, hasAudio: false, audioChannels: nil, audioRate: nil)),
            FCPAsset(name: "IMG_0002", url: URL(fileURLWithPath: "/tmp/IMG_0002.MOV"), duration: RationalTime(8),
                     kind: .video(v30, hasAudio: true, audioChannels: 2, audioRate: 48000)),
            FCPAsset(name: "song", url: URL(fileURLWithPath: "/tmp/song.m4a"), duration: RationalTime(30),
                     kind: .audio(channels: 2, rate: 44100)),
            FCPAsset(name: "logo", url: URL(fileURLWithPath: "/tmp/logo.png"), duration: .zero,
                     kind: .still(FCPFormat(name: "FFVideoFormatRateUndefined", frameDuration: nil, width: 1000, height: 400))),
        ]
        var clips = [
            FCPSpineClip(assetIndex: 0, name: "DJI_0001", duration: fd * 60, sourceIn: RationalTime(3600) + RationalTime(2),
                         speed: RationalTime(1, 2),
                         transform: FCPTransform(positionX: 10, positionY: -5, scale: 1.2, rotation: 2, scaleEnd: scaleEnd),
                         volumeDB: -96),
            FCPSpineClip(assetIndex: 1, name: "IMG_0002", duration: fd * 45, sourceIn: RationalTime(1), volumeDB: -96),
        ]
        if gapFirst { clips.insert(.gap(duration: fd * 30), at: 0) }
        let total = clips.reduce(RationalTime.zero) { $0 + $1.duration }
        let overlays = [
            FCPOverlay(assetIndex: 3, name: "logo (intro)", start: .zero, duration: fd * 60, transform: FCPTransform(scale: 0.66)),
            FCPOverlay(assetIndex: 3, name: "logo (outro)", start: total - fd * 45, duration: fd * 45, transform: FCPTransform(scale: 0.66)),
        ]
        let music = FCPMusic(assetIndex: 2, name: "song", sourceIn: fd * 15, duration: total,
                             markers: [FCPMarker(time: fd * 15, name: "Beat 1"), FCPMarker(time: fd * 60, name: "Beat 2"),
                                       FCPMarker(time: fd * 500, name: "Beat 3")])
        return FCPTimeline(eventName: "ReelPrep", projectName: "Test & reel", assets: assets, clips: clips,
                           overlays: overlays, music: music)
    }

    static func compact(_ xml: String) -> String {
        xml.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.joined()
    }

    @Test func isWellFormedXMEML() throws {
        let xml = try FCP7XMLWriter.document(for: Self.sample())
        let doc = try XMLDocument(xmlString: xml)
        #expect(doc.rootElement()?.name == "xmeml")
        #expect(doc.rootElement()?.attribute(forName: "version")?.stringValue == "4")
        let seq = try #require(try doc.nodes(forXPath: "/xmeml/sequence").first as? XMLElement)
        #expect(seq.elements(forName: "name").first?.stringValue == "Test & reel")
        #expect(seq.elements(forName: "duration").first?.stringValue == "105")
        #expect(try doc.nodes(forXPath: "//sequence/media/video/track").count == 2)
        #expect(try doc.nodes(forXPath: "//sequence/media/audio/track").count == 1)
    }

    @Test func sequenceFormat() throws {
        let xml = Self.compact(try FCP7XMLWriter.document(for: Self.sample()))
        #expect(xml.contains("<rate><timebase>30</timebase><ntsc>TRUE</ntsc></rate>"))
        #expect(xml.contains("<width>1080</width><height>1920</height>"))
    }

    @Test func cutsInFramesWithSlowMotion() throws {
        let xml = Self.compact(try FCP7XMLWriter.document(for: Self.sample()))
        // 50 %: 2 s into the file is 4 s of retimed clip = 120 frames at 29.97; out − in = the 60 frames on the timeline.
        #expect(xml.contains("<name>DJI_0001</name><enabled>TRUE</enabled><duration>599</duration><rate><timebase>30</timebase><ntsc>TRUE</ntsc></rate><start>0</start><end>60</end><in>120</in><out>180</out>"))
        #expect(xml.contains("<parameterid>speed</parameterid><name>speed</name><valuemin>-100000</valuemin><valuemax>100000</valuemax><value>50</value>"))
        // The iPhone clip follows straight on, 1 s in = 30 frames; no time remap at 100 %.
        #expect(xml.contains("<start>60</start><end>105</end><in>30</in><out>75</out>"))
        #expect(xml.components(separatedBy: "<effectid>timeremap</effectid>").count == 2)
    }

    @Test func motionFromTheFraming() throws {
        let xml = Self.compact(try FCP7XMLWriter.document(for: Self.sample()))
        // 3840×2160 filling 1080×1920 is 88.89 %, times the framing's 1.2.
        #expect(xml.contains("<parameterid>scale</parameterid><name>Scale</name><valuemin>0</valuemin><valuemax>1000</valuemax><value>106.6667</value>"))
        // Turned 2° counter-clockwise = −2° in FCP7's clockwise rotation.
        #expect(xml.contains("<parameterid>rotation</parameterid><name>Rotation</name><valuemin>-8640</valuemin><valuemax>8640</valuemax><value>-2</value>"))
        // 10 % of the height to the right = 0.1778 of the width; 5 % down (y up in FCP) = +0.05 (y down in FCP7).
        #expect(xml.contains("<horiz>0.1778</horiz><vert>0.05</vert>"))
        // The upright 1080×1920 clip fills at its own size.
        #expect(xml.contains("<value>100</value>"))
    }

    @Test func zoomEffectAsScaleKeyframes() throws {
        let xml = Self.compact(try FCP7XMLWriter.document(for: Self.sample(scaleEnd: 1.25)))
        #expect(xml.contains("<keyframe><when>120</when><value>106.6667</value></keyframe><keyframe><when>180</when><value>111.1111</value></keyframe>"))
    }

    @Test func logoStillsOnTrackTwo() throws {
        let xml = Self.compact(try FCP7XMLWriter.document(for: Self.sample()))
        // 1000×400 fitted into 1080×1920 is 108 %, times 0.66 = 66 % of the frame width.
        #expect(xml.contains("<name>logo (intro)</name><enabled>TRUE</enabled><duration>60</duration><rate><timebase>30</timebase><ntsc>TRUE</ntsc></rate><start>0</start><end>60</end><in>0</in><out>60</out><stillframe>TRUE</stillframe>"))
        #expect(xml.contains("<start>60</start><end>105</end><in>0</in><out>45</out><stillframe>TRUE</stillframe><file id=\"file-4\"/>"))
        #expect(xml.contains("<value>71.28</value>"))
    }

    @Test func songAndBeatMarkers() throws {
        let xml = Self.compact(try FCP7XMLWriter.document(for: Self.sample()))
        #expect(xml.contains("<name>song</name><enabled>TRUE</enabled><duration>899</duration><rate><timebase>30</timebase><ntsc>TRUE</ntsc></rate><start>0</start><end>105</end><in>15</in><out>120</out>"))
        #expect(xml.contains("<marker><name>Beat 1</name><comment></comment><in>15</in><out>-1</out></marker>"))
        #expect(xml.contains("<marker><name>Beat 2</name><comment></comment><in>60</in><out>-1</out></marker>"))
        #expect(!xml.contains("Beat 3"))  // past the end of the reel
    }

    @Test func filesWrittenOnceWithEncodedPaths() throws {
        let xml = try FCP7XMLWriter.document(for: Self.sample())
        #expect(xml.contains("<pathurl>file://localhost/tmp/reel%20%26%20co/DJI_0001.MP4</pathurl>"))
        #expect(xml.components(separatedBy: "<pathurl>").count == 5)  // four files, each once
    }

    @Test func emptySlotIsAGap() throws {
        let xml = Self.compact(try FCP7XMLWriter.document(for: Self.sample(gapFirst: true)))
        // Nothing on track 1 for the first 30 frames: the drone cut starts at 30.
        #expect(xml.contains("<start>30</start><end>90</end><in>120</in><out>180</out>"))
        #expect(!xml.contains("Empty"))
    }

    @Test func roundsToNearestFrame() {
        #expect(FCP7XMLWriter.roundedFrames(RationalTime(1), .fd29_97) == 30)
        #expect(FCP7XMLWriter.roundedFrames(RationalTime(10), .fd29_97) == 300)
        #expect(FCP7XMLWriter.roundedFrames(.fd29_97 * 7, .fd29_97) == 7)
    }
}
