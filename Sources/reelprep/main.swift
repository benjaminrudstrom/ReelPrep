import Foundation
import FCPXMLKit
import ReelCore
import ReelMedia

let usage = """
reelprep — beat-cut a vertical reel and write it for Final Cut Pro (FCPXML), Premiere Pro or DaVinci Resolve
(Final Cut Pro 7 XML), or render it.

Usage:
  reelprep --clips <folder or files…> --song <audio> [--logo <png>] [options]

Required:
  --clips <path…>        A folder of clips (.mov .mp4 .m4v), or clip files. Ordered by capture time.
  --song <file>          The song (.mp3 .m4a .wav .aif .aac .caf).
  --logo <file.png>      The logo; remembered for next time, so it can be left out later.

Options:
  --editor <name>        finalcut (default), premiere or resolve: FCPXML for Final Cut, Final Cut Pro 7 XML
                         for the other two (no stabilization in that file).
  --out <file>           Where to write (default: ./<clips folder name>.fcpxml, or .xml for premiere/resolve).
  --name <text>          Project name in the editor (default: the clips folder name).
  -n, --beats-per-cut N  Longest cut in beats (default 4, remembered). Cuts are fitted to the song so as many
                         clips as possible get in, down to about --min-cut seconds each.
  --min-cut S            Shortest cut in seconds when fitting (default 1).
  --fixed                Every cut exactly N beats instead (clips that don't fit are left out).
  --song-start-beat K    Start the song at detected beat K (0 = first beat). Default: the song's first frame.
  --max-length S         Longest reel in seconds.
  --intro-beats K        Intro logo cuts out after K beats (default: end of the first cut).
  --outro-beats K        Outro logo cuts in K beats before the end (default: start of the last cut).
  --beats <file>         Use these beat times (seconds, one per line) instead of detecting.
  --library <x.fcpbundle>
                         Final Cut library to import into (remembered). Default: the one used most recently.
  --detect               Use ReelPrep's own beat detection, ignoring hand-corrected and Final Cut's beats.
                         (By default: beats corrected in ReelPrepApp, else Final Cut's Beat Detection, else ReelPrep's.)
  --write-beats <file>   Save the detected beat times (to correct by hand and pass back with --beats).
  --no-stabilize         Leave out FCP's automatic stabilization.
  --no-music, --no-logo, --no-retime
                         Leave the song / the logo / the 50 % slow motion out of the FCPXML (for tracking down
                         import problems; beats still come from the song).
  --open                 Open the result in the editor (Resolve: started, the file shown to import).
  --render <file.mp4>    Render the reel to a video file instead (no grading or stabilization; .mp4 or .mov).
                         With --out as well, the project file is written too.
  --tilt D               Tilt every cut D degrees (counter-clockwise), cropped to fill.
  --zoom-effect P        A slow zoom over every cut: P percent in (or out, when negative).
  -h, --help

Clip sound is always muted. 50/59.94/60 fps clips play at 50 % (slow motion) on the 29.97 fps timeline.
"""

struct Failure: Error, CustomStringConvertible { let description: String }

struct Options {
    var clips: [String] = []
    var song: String?
    var logo: String?
    var out: String?
    var name: String?
    var beatsFile: String?
    var writeBeats: String?
    var open = false
    var editor = Editor.finalCut
    var render: String?
    var tilt = 0.0, push = 0.0
    var detect = false
    var library: String?
    var noMusic = false, noLogo = false, noRetime = false
    var settings = PlanSettings()
    var beatsPerCutGiven = false
}

var defaults: UserDefaults { UserDefaults(suiteName: "com.reelprep.ReelPrep") ?? .standard }

func parse(_ args: [String]) throws -> Options {
    var o = Options()
    var i = 0
    func value(_ flag: String) throws -> String {
        i += 1
        guard i < args.count, !args[i].hasPrefix("--") else { throw Failure(description: "\(flag) needs a value.") }
        return args[i]
    }
    func int(_ flag: String) throws -> Int {
        let v = try value(flag)
        guard let n = Int(v), n >= 0 else { throw Failure(description: "\(flag) needs a whole number, got \(v).") }
        return n
    }
    while i < args.count {
        let a = args[i]
        switch a {
        case "-h", "--help": print(usage); exit(0)
        case "--clips":
            while i + 1 < args.count, !args[i + 1].hasPrefix("-") { i += 1; o.clips.append(args[i]) }
            if o.clips.isEmpty { throw Failure(description: "--clips needs a folder or files.") }
        case "--song": o.song = try value(a)
        case "--logo": o.logo = try value(a)
        case "--out": o.out = try value(a)
        case "--name": o.name = try value(a)
        case "-n", "--beats-per-cut":
            o.settings.beatsPerCut = try int(a)
            if o.settings.beatsPerCut < 1 { throw Failure(description: "--beats-per-cut must be at least 1.") }
            o.beatsPerCutGiven = true
        case "--song-start-beat": o.settings.songStartBeat = try int(a)
        case "--max-length":
            let v = try value(a)
            guard let s = Double(v), s > 0 else { throw Failure(description: "--max-length needs seconds, got \(v).") }
            o.settings.maxLength = s
        case "--intro-beats": o.settings.introBeats = try int(a)
        case "--outro-beats": o.settings.outroBeats = try int(a)
        case "--beats": o.beatsFile = try value(a)
        case "--write-beats": o.writeBeats = try value(a)
        case "--no-stabilize": o.settings.stabilize = false
        case "--fixed": o.settings.fixedCuts = true
        case "--detect": o.detect = true
        case "--library": o.library = try value(a)
        case "--min-cut":
            let v = try value(a)
            guard let s = Double(v), s > 0 else { throw Failure(description: "--min-cut needs seconds, got \(v).") }
            o.settings.minCutLength = s
        case "--no-music": o.noMusic = true
        case "--no-logo": o.noLogo = true
        case "--no-retime": o.noRetime = true
        case "--open": o.open = true
        case "--editor":
            let v = try value(a)
            guard let e = Editor(argument: v) else { throw Failure(description: "--editor is finalcut, premiere or resolve, got \(v).") }
            o.editor = e
        case "--render": o.render = try value(a)
        case "--tilt", "--zoom-effect":
            let v = try value(a)
            guard let d = Double(v) else { throw Failure(description: "\(a) needs a number, got \(v).") }
            if a == "--tilt" { o.tilt = d } else { o.push = d }
        default: throw Failure(description: "Unknown option \(a). See reelprep --help.")
        }
        i += 1
    }
    return o
}

func expand(_ path: String) -> URL {
    URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardizedFileURL
}

/// Sorts the given clip paths (folders are read one level deep); unsupported files are reported.
func collectClips(_ paths: [String]) throws -> (clips: [URL], rejected: [String]) {
    var clips: [URL] = [], rejected: [String] = []
    let fm = FileManager.default
    for p in paths {
        let url = expand(p)
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else { throw Failure(description: "Not found: \(url.path)") }
        let files = isDir.boolValue
            ? try fm.contentsOfDirectory(at: url, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
                .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) != true }
            : [url]
        for f in files {
            if MediaTypes.kind(of: f) == .video { clips.append(f) } else { rejected.append(f.lastPathComponent) }
        }
    }
    return (clips, rejected)
}

func fmt(_ s: Double) -> String { String(format: "%.2f s", s) }

@MainActor func run() async throws {
    var o = try parse(Array(CommandLine.arguments.dropFirst()))
    guard !o.clips.isEmpty, let songPath = o.song else {
        print(usage)
        throw Failure(description: "Clips and a song are required.")
    }
    if !o.beatsPerCutGiven, defaults.integer(forKey: "beatsPerCut") > 0 {
        o.settings.beatsPerCut = defaults.integer(forKey: "beatsPerCut")
    }

    // Inputs.
    let (clipURLs, rejected) = try collectClips(o.clips)
    if !rejected.isEmpty {
        print("Not clips, left out: \(rejected.joined(separator: ", ")) (supported: \(MediaTypes.video.sorted().joined(separator: ", ")))")
    }
    guard !clipURLs.isEmpty else { throw Failure(description: "No clips found.") }
    let songURL = expand(songPath)
    guard MediaTypes.kind(of: songURL) == .audio else {
        throw Failure(description: "\(songURL.lastPathComponent) isn't a supported song file (\(MediaTypes.audio.sorted().joined(separator: ", "))).")
    }
    let logoPath = o.logo ?? defaults.string(forKey: "logoPath")
    guard let logoPath else { throw Failure(description: "A logo PNG is required the first time (--logo).") }
    let logoURL = expand(logoPath)
    guard MediaTypes.kind(of: logoURL) == .logo else { throw Failure(description: "The logo must be a PNG: \(logoURL.lastPathComponent)") }
    guard FileManager.default.fileExists(atPath: logoURL.path) else {
        throw Failure(description: "Logo not found: \(logoURL.path)" + (o.logo == nil ? " (remembered from last time; give --logo)." : ""))
    }
    if o.logo == nil { print("Logo: \(logoURL.lastPathComponent) (remembered)") }
    // Metadata.
    var clips: [ClipInfo] = []
    for u in clipURLs {
        do { clips.append(try await MediaProbe.clip(u)) } catch { print("Left out \(u.lastPathComponent): \(error)") }
    }
    clips = sortedByCaptureTime(clips)
    if o.noRetime { for i in clips.indices where clips[i].fps >= 47 { clips[i].fps = 30 } }
    guard !clips.isEmpty else { throw Failure(description: "None of the clips could be read.") }
    let df = DateFormatter()
    df.dateFormat = "yyyy-MM-dd HH:mm:ss"
    print("\nClips (\(clips.count), by capture time):")
    for c in clips {
        let rate = c.speed == RationalTime(1) ? "" : "  → 50 % slow motion"
        let odd = (c.fps < 29 && c.fps > 1) ? "  (plays at 100 %, FCP conforms)" : ""
        print(String(format: "  %@  %4d×%-4d %6.2f fps  %7.2f s  %@  %@%@%@",
                     c.name.padding(toLength: 14, withPad: " ", startingAt: 0), c.width, c.height, c.fps,
                     c.duration.seconds, c.captureDate.map { df.string(from: $0) } ?? "no date        ",
                     c.device.rawValue + (c.deviceModel.map { " (\($0))" } ?? ""), rate, odd))
    }

    var song = try await MediaProbe.song(songURL)
    var logo = try MediaProbe.logo(logoURL)

    // Beats.
    var beats: [Double]
    if let bf = o.beatsFile {
        let text = try String(contentsOf: expand(bf), encoding: .utf8)
        beats = text.split(whereSeparator: \.isNewline).compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }.sorted()
        print("\nSong: \(song.name), \(fmt(song.duration.seconds)); \(beats.count) beats from \(bf)")
    } else {
        let found = try BeatStore.beats(for: songURL, detect: o.detect)
        beats = found.beats
        let bpm = (found.bpm ?? BeatList(beats, duration: song.duration.seconds).bpm).map { String(format: "%.1f BPM, ", $0) } ?? ""
        print("\nSong: \(song.name), \(fmt(song.duration.seconds)); \(bpm)\(beats.count) beats, \(found.source.rawValue)"
              + (found.source == .reelPrep && !o.detect ? " (turn on Final Cut's Beat Detection for the song, or correct them in ReelPrepApp)" : ""))
    }
    if let wb = o.writeBeats {
        try beats.map { String(format: "%.4f", $0) }.joined(separator: "\n").appending("\n")
            .write(to: expand(wb), atomically: true, encoding: .utf8)
        print("Beat times written to \(expand(wb).path)")
    }
    guard beats.count >= 2 else { throw Failure(description: "Too few beats found in the song; pass them with --beats.") }

    // Plan.
    let plan = EditPlanner.plan(clips: clips, beats: beats, songDuration: song.duration.seconds, settings: o.settings)
    guard !plan.slots.isEmpty else {
        plan.warnings.forEach { print("  ! \($0)") }
        throw Failure(description: "No clip could be placed on the beats.")
    }
    let fd = plan.frameDuration
    print(o.settings.fixedCuts ? "\nCuts (every \(o.settings.beatsPerCut) beats, 29.97 fps timeline):"
          : "\nCuts (fitted to the song, at most \(o.settings.beatsPerCut) beats, 29.97 fps timeline):")
    for (i, s) in plan.slots.enumerated() {
        let c = clips[s.clipIndex]
        print(String(format: "  %2d  %7.2f–%-7.2f %d beats  %@  from %.2f s%@", i + 1,
                     (fd * s.startFrame).seconds, (fd * s.endFrame).seconds, s.beats, c.name,
                     (s.sourceIn - c.start).seconds, s.speed == RationalTime(1) ? "" : " at 50 %"))
    }
    if let e = plan.introEndFrame { print("  Intro logo: 0.00–\(fmt((fd * e).seconds))") }
    if let s = plan.outroStartFrame { print("  Outro logo: \(fmt((fd * s).seconds))–end") }
    print("  Reel length: \(fmt(plan.duration.seconds)), \(plan.beatFrames.count) beat markers")
    for w in plan.warnings { print("  ! \(w)") }

    // FCPXML. Files with "%" in their names go to Final Cut as clean-named hard links (it freezes on "%").
    var logoOpt: LogoInfo? = logo
    if o.editor == .finalCut {
        for note in try ReelExporter.prepareMedia(clips: &clips, song: &song, logo: &logoOpt) { print(note) }
    }
    logo = logoOpt!
    let firstClipFolder = clipURLs[0].deletingLastPathComponent()
    let name = o.name ?? (o.clips.count == 1 && clipURLs.count > 1 ? expand(o.clips[0]).lastPathComponent : firstClipFolder.lastPathComponent)
    var transforms: [Int: FCPTransform] = [:]
    if o.tilt != 0 || o.push != 0 {
        for (i, c) in clips.enumerated() {
            transforms[i] = Reframe(angle: o.tilt, push: o.push).clamped(w: Double(c.width), h: Double(c.height))
                .fcpTransform(w: Double(c.width), h: Double(c.height))
        }
    }
    var timeline = ReelTimelineBuilder.timeline(plan: plan, clips: clips, song: song, logo: logo, settings: o.settings,
                                                projectName: name, transforms: transforms)
    // Import straight into a library, so Final Cut doesn't ask which one.
    var libraryURL: URL?
    if let l = o.library ?? defaults.string(forKey: "libraryPath") {
        libraryURL = expand(l)
        if !FileManager.default.fileExists(atPath: libraryURL!.path) {
            if o.library != nil { throw Failure(description: "Library not found: \(libraryURL!.path)") }
            libraryURL = nil
        }
    }
    if libraryURL == nil {
        libraryURL = ReelExporter.mostRecentLibrary()
    }
    if o.editor != .finalCut { libraryURL = nil }
    timeline.libraryLocation = libraryURL
    if let l = libraryURL { print("Imports into the library \(l.deletingPathExtension().lastPathComponent) (\(l.deletingLastPathComponent().path))") }
    if o.noMusic { timeline.music = nil }
    if o.noLogo { timeline.overlays = [] }
    if o.noMusic || o.noLogo {
        // Drop assets nothing refers to any more, renumbering the references.
        var used = Set(timeline.clips.map(\.assetIndex) + timeline.overlays.map(\.assetIndex))
        if let m = timeline.music { used.insert(m.assetIndex) }
        var map: [Int: Int] = [:]
        var kept: [FCPAsset] = []
        for (i, a) in timeline.assets.enumerated() where used.contains(i) { map[i] = kept.count; kept.append(a) }
        timeline.assets = kept
        for i in timeline.clips.indices { timeline.clips[i].assetIndex = map[timeline.clips[i].assetIndex]! }
        for i in timeline.overlays.indices { timeline.overlays[i].assetIndex = map[timeline.overlays[i].assetIndex]! }
        if timeline.music != nil { timeline.music!.assetIndex = map[timeline.music!.assetIndex]! }
    }
    if let r = o.render {
        let videoURL = expand(r)
        print("Rendering \(videoURL.lastPathComponent)…")
        let start = Date()
        try await ReelRenderer.render(timeline, to: videoURL)
        print(String(format: "Wrote %@ in %.1f s", videoURL.path, Date().timeIntervalSince(start)))
        if o.out == nil { return }
    }
    let outURL = o.out.map(expand) ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        .appendingPathComponent(name + "." + o.editor.fileExtension)
    if let dtd = try ReelExporter.write(timeline, to: outURL, for: o.editor) {
        print("\nValid against \(dtd) (from Final Cut Pro).")
    } else if o.editor == .finalCut {
        print("\nFinal Cut Pro not found in /Applications: not validated against its DTD.")
    } else {
        print("\nFinal Cut Pro 7 XML for \(o.editor.name) (well-formed; there is no DTD to check it against).")
    }
    print("Wrote \(outURL.path)")

    defaults.set(logoURL.path, forKey: "logoPath")
    defaults.set(o.settings.beatsPerCut, forKey: "beatsPerCut")
    if o.library != nil, let l = libraryURL { defaults.set(l.path, forKey: "libraryPath") }

    if o.open { print(try ReelExporter.open(outURL, in: o.editor)) }
}

do {
    try await run()
} catch {
    FileHandle.standardError.write(Data("reelprep: \(error)\n".utf8))
    exit(1)
}
