import Foundation
import Testing
@testable import FCPXMLKit

@Suite struct RationalTimeTests {
    @Test func reducesAndFormats() {
        #expect(RationalTime(2002, 60000).fcpxml == "1001/30000s")
        #expect(RationalTime(60, 30).fcpxml == "2s")
        #expect(RationalTime.zero.fcpxml == "0s")
        #expect((RationalTime.fd29_97 * 30).fcpxml == "1001/1000s")
    }

    @Test func arithmetic() {
        let a = RationalTime(1001, 30000), b = RationalTime(1001, 60000)
        #expect(a + b == RationalTime(3003, 60000))
        #expect(a - b == b)
        #expect(a / b == RationalTime(2))
        #expect(b < a)
        #expect(RationalTime(10).floorDiv(.fd29_97) == 299)
    }
}

@Suite struct FCPXMLWriterTests {
    static func sample() -> FCPTimeline {
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
        let clips = [
            FCPSpineClip(assetIndex: 0, name: "DJI_0001", duration: fd * 60, sourceIn: RationalTime(3600) + RationalTime(2),
                         speed: RationalTime(1, 2), transform: FCPTransform(positionX: 10, positionY: -5, scale: 1.2), volumeDB: -96),
            FCPSpineClip(assetIndex: 1, name: "IMG_0002", duration: fd * 45, sourceIn: RationalTime(1), volumeDB: -96),
        ]
        let overlays = [
            FCPOverlay(assetIndex: 3, name: "logo (intro)", start: .zero, duration: fd * 60, transform: FCPTransform(scale: 0.66)),
            FCPOverlay(assetIndex: 3, name: "logo (outro)", start: fd * 60, duration: fd * 45, transform: FCPTransform(scale: 0.66)),
        ]
        let music = FCPMusic(assetIndex: 2, name: "song", sourceIn: fd * 15, duration: fd * 105,
                             markers: [FCPMarker(time: fd * 15, name: "Beat 1"), FCPMarker(time: fd * 60, name: "Beat 2")])
        return FCPTimeline(eventName: "ReelPrep", projectName: "Test reel", assets: assets, clips: clips,
                           overlays: overlays, music: music)
    }

    @Test func writesExpectedStructure() throws {
        let xml = try FCPXMLWriter.document(for: Self.sample())
        #expect(xml.contains(#"<fcpxml version="1.14">"#))
        #expect(xml.contains(#"name="FFVideoFormat1080x1920p2997" frameDuration="1001/30000s" width="1080" height="1920""#))
        // Retimed 50 %: local start = 3600 + 2 / 0.5 = 3604 s; map covers the whole file.
        #expect(xml.contains(#"offset="0s" name="DJI_0001" start="3604s" duration="1001/500s""#))
        #expect(xml.contains(#"<timept time="3600s" value="3600s" interp="smooth2"/>"#))
        #expect(xml.contains(#"<timept time="3620s" value="3610s" interp="smooth2"/>"#))
        #expect(xml.contains(#"<adjust-conform type="fill"/>"#))
        #expect(xml.contains(#"<adjust-transform position="10 -5" scale="1.2 1.2"/>"#))
        #expect(xml.contains(#"<adjust-stabilization type="automatic"/>"#))
        #expect(xml.contains(#"<adjust-volume amount="-96dB"/>"#))
        // Second cut directly after the first, not retimed.
        #expect(xml.contains(#"offset="1001/500s" name="IMG_0002" start="1s""#))
        // Song on lane -1 from the first frame, markers in song time.
        #expect(xml.contains(#"lane="-1" offset="3604s" name="song" start="1001/2000s" duration="7007/2000s" audioRole="music""#))
        #expect(xml.contains(#"<marker start="1001/1000s" duration="1001/30000s" value="Beat 1"/>"#))
        // Logos: intro on cut 1 at its local start, outro on cut 2.
        #expect(xml.contains(#"lane="1" offset="3604s" name="logo (intro)""#))
        #expect(xml.contains(#"lane="1" offset="1s" name="logo (outro)""#))
        #expect(xml.contains("file:///tmp/reel%20&amp;%20co/DJI_0001.MP4"))
        #expect(!xml.contains("transition"))
    }

    @Test func validAgainstFinalCutDTD() throws {
        guard let dtd = FCPXMLValidator.dtdURL() else { return } // FCP not installed
        try FCPXMLValidator.validate(try FCPXMLWriter.document(for: Self.sample()), dtd: dtd)
    }

    @Test func namesTheLibraryToImportInto() throws {
        var t = Self.sample()
        t.libraryLocation = URL(fileURLWithPath: "/Users/someone/Movies/Reels.fcpbundle")
        let xml = try FCPXMLWriter.document(for: t)
        #expect(xml.contains(#"<library location="file:///Users/someone/Movies/Reels.fcpbundle/">"#))
        if let dtd = FCPXMLValidator.dtdURL() { try FCPXMLValidator.validate(xml, dtd: dtd) }
    }

    @Test func emptySlotIsAGapCarryingTheAnchors() throws {
        var t = Self.sample()
        t.clips[0] = .gap(duration: RationalTime.fd29_97 * 60)
        let xml = try FCPXMLWriter.document(for: t)
        #expect(xml.contains(#"<gap name="Empty" offset="0s" start="0s" duration="1001/500s">"#))
        #expect(xml.contains(#"lane="-1" offset="0s" name="song""#))
        #expect(xml.contains(#"lane="1" offset="0s" name="logo (intro)""#))
        if let dtd = FCPXMLValidator.dtdURL() { try FCPXMLValidator.validate(xml, dtd: dtd) }
    }

    @Test func tiltIsTheTransformsRotation() throws {
        var t = Self.sample()
        t.clips[0].transform.rotation = -1.5
        let xml = try FCPXMLWriter.document(for: t)
        #expect(xml.contains(#"<adjust-transform position="10 -5" scale="1.2 1.2" rotation="-1.5"/>"#))
        if let dtd = FCPXMLValidator.dtdURL() { try FCPXMLValidator.validate(xml, dtd: dtd) }
    }

    @Test func pushIsKeyframedScale() throws {
        var t = Self.sample()
        t.clips[0].transform.scaleEnd = 1.236
        let xml = try FCPXMLWriter.document(for: t)
        // The first cut is retimed: local time 3604 s to 3604 s + its length.
        #expect(xml.contains(#"<adjust-transform position="10 -5" scale="1.2 1.2"><param name="scale"><keyframeAnimation><keyframe time="3604s" value="1.2 1.2" curve="linear"/><keyframe time="#)
            || xml.contains(#"<keyframe time="3604s" value="1.2 1.2" curve="linear"/>"#))
        #expect(xml.contains(#"value="1.236 1.236" curve="linear"/>"#))
        if let dtd = FCPXMLValidator.dtdURL() { try FCPXMLValidator.validate(xml, dtd: dtd) }
    }

    @Test func validatorRejectsBadXML() throws {
        guard let dtd = FCPXMLValidator.dtdURL() else { return }
        let bad = #"<?xml version="1.0"?><!DOCTYPE fcpxml><fcpxml version="1.14"><spine/></fcpxml>"#
        #expect(throws: (any Error).self) { try FCPXMLValidator.validate(bad, dtd: dtd) }
    }

    @Test func rejectsSourceRangeOutsideFile() {
        var t = Self.sample()
        t.clips[1].sourceIn = RationalTime(7)
        #expect(throws: FCPXMLError.self) { try FCPXMLWriter.document(for: t) }
    }
}
