import AppKit
import Foundation
import Observation
import FCPXMLKit
import ReelCore
import ReelMedia

/// The app's state: everything dropped on the window, and the cuts and per-clip choices.
/// Drops are sorted into clips, the song and the logo and loaded in place; the timeline fills itself.
@MainActor @Observable
public final class ReelProject {
    public private(set) var clipURLs: [URL] = []
    public private(set) var songURL: URL?
    public private(set) var logoURL: URL?
    /// Messages about files that were left out or replaced (shown until the next drop).
    public var notices: [String] = []

    /// All clips, in reel order (what doesn't fit the song comes last, unused); empty slots too.
    public private(set) var clips: [ClipInfo] = [] { didSet { edited() } }
    /// Clips the user left out of the reel (still in the library).
    public var excluded: Set<URL> = [] { didSet { edited() } }
    /// The clips the reel is planned from; `Slot.clipIndex` indexes this.
    public var reelClips: [ClipInfo] { clips.filter { !excluded.contains($0.url) } }
    public private(set) var song: SongInfo?
    public private(set) var logo: LogoInfo?
    public private(set) var proxies: [URL: URL] = [:]
    public let beats = BeatEditorModel()
    /// Where the user put each clip's window (seconds from the clip's start) and its framing.
    public var inPoints: [URL: Double] = [:] { didSet { edited() } }
    public var reframes: [URL: Reframe] = [:] { didSet { edited() } }
    /// Cut lengths in beats the user set by dragging a cut's edge on the timeline.
    public var beatCounts: [URL: Int] = [:] { didSet { edited() } }
    public var settings: PlanSettings { didSet { saveSettings(); edited() } }
    public var selectedClip: URL?
    public private(set) var loading = false
    public private(set) var loadingStatus = ""
    public private(set) var loadingProgress = 0.0
    public var exportMessage: String?
    /// The editor "Open in Editor" writes for and opens (remembered; not an edit to undo).
    public var editor: Editor = .finalCut { didSet { defaults.set(editor.rawValue, forKey: "editor") } }
    /// The level grid over the preview, while the tilt is being set.
    public var levelGrid = false
    @ObservationIgnored private var refreshAgain = false

    /// Undo: everything the user edits (the cuts and their order, empty slots, left-out clips, in-points,
    /// framing, cut lengths, logo and cut settings, beats), as snapshots. Changes close together (a drag,
    /// a slider) are one step: a step ends after 0.6 s without changes.
    struct EditState {
        var clipURLs: [URL], clips: [ClipInfo], excluded: Set<URL>, inPoints: [URL: Double], reframes: [URL: Reframe]
        var beatCounts: [URL: Int], settings: PlanSettings, beats: BeatList
    }
    @ObservationIgnored private var undoStack: [EditState] = []
    @ObservationIgnored private var redoStack: [EditState] = []
    /// The state before the change being made now (or the current one when nothing is changing).
    @ObservationIgnored private var settled: EditState?
    @ObservationIgnored private var burst: Task<Void, Never>?
    /// Off while restoring a step and while files are loading (a drop isn't an edit to undo).
    @ObservationIgnored private var recording = true

    let defaults = UserDefaults.standard

    public init() {
        var s = PlanSettings()
        if defaults.integer(forKey: "beatsPerCut") > 0 { s.beatsPerCut = defaults.integer(forKey: "beatsPerCut") }
        if defaults.double(forKey: "minCutLength") > 0 { s.minCutLength = defaults.double(forKey: "minCutLength") }
        s.fixedCuts = defaults.bool(forKey: "fixedCuts")
        settings = s
        editor = defaults.string(forKey: "editor").flatMap(Editor.init(rawValue:)) ?? .finalCut
        beats.undoHost = self
        settled = state
    }

    var state: EditState {
        EditState(clipURLs: clipURLs, clips: clips, excluded: excluded, inPoints: inPoints, reframes: reframes, beatCounts: beatCounts,
                  settings: settings, beats: beats.beats)
    }

    /// Called on every edit: the first change of a step saves the state before it.
    func edited() {
        guard recording else { return }
        if burst == nil, let s = settled {
            undoStack.append(s)
            if undoStack.count > 200 { undoStack.removeFirst() }
            redoStack = []
            updateUndoButtons()
        }
        burst?.cancel()
        burst = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(600))
            if !Task.isCancelled { self?.settle() }
        }
    }

    private func settle() {
        burst?.cancel()
        burst = nil
        settled = state
    }

    public func undo() {
        settle()
        guard let previous = undoStack.popLast() else { return }
        redoStack.append(state)
        apply(previous)
    }

    public func redo() {
        settle()
        guard let next = redoStack.popLast() else { return }
        undoStack.append(state)
        apply(next)
    }

    private func apply(_ s: EditState) {
        recording = false
        clipURLs = s.clipURLs
        clips = s.clips
        excluded = s.excluded
        inPoints = s.inPoints
        reframes = s.reframes
        beatCounts = s.beatCounts
        settings = s.settings
        beats.restore(s.beats)
        recording = true
        settled = s
        if let sel = selectedClip, !clips.contains(where: { $0.url == sel }) { selectedClip = nil }
        updateUndoButtons()
    }

    /// Forgets the undo history (a new reel, or a new song: older steps had other beats).
    func clearUndo() {
        undoStack = []
        redoStack = []
        settle()
        updateUndoButtons()
    }

    private func updateUndoButtons() {
        beats.canUndo = !undoStack.isEmpty
        beats.canRedo = !redoStack.isEmpty
    }

    func saveSettings() {
        defaults.set(settings.beatsPerCut, forKey: "beatsPerCut")
        defaults.set(settings.minCutLength, forKey: "minCutLength")
        defaults.set(settings.fixedCuts, forKey: "fixedCuts")
    }

    public var hasEverything: Bool { song != nil && clips.contains { !$0.isPlaceholder } }

    // MARK: Drops

    /// Adds dropped files (folders one level deep) and loads what's new.
    public func drop(_ urls: [URL]) async {
        add(urls)
        await refresh()
    }

    /// Sorts files into clips, the song and the logo (without loading them).
    public func add(_ urls: [URL]) {
        var newNotices: [String] = []
        var rejected: [String] = []
        var songs: [URL] = []
        for url in urls {
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else { continue }
            let files = isDir.boolValue
                ? ((try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? [])
                    .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
                : [url]
            for f in files {
                switch MediaTypes.kind(of: f) {
                case .video: if !clipURLs.contains(f) { clipURLs.append(f) }
                case .audio: songs.append(f)
                case .logo:
                    if logoURL != nil && logoURL != f { newNotices.append("Logo replaced by \(f.lastPathComponent).") }
                    logoURL = f
                case nil:
                    if !(isDir.boolValue && f.hasDirectoryPath) { rejected.append(f.lastPathComponent) }
                }
            }
        }
        if let s = songs.first {
            if songURL != nil && songURL != s { newNotices.append("Song replaced by \(s.lastPathComponent).") }
            songURL = s
            if songs.count > 1 {
                newNotices.append("One song per reel: kept \(s.lastPathComponent), left out \(songs.dropFirst().map(\.lastPathComponent).joined(separator: ", ")).")
            }
        }
        if !rejected.isEmpty {
            newNotices.append("Not supported, left out: \(rejected.joined(separator: ", ")). Clips: .mov .mp4 .m4v · song: .mp3 .m4a .wav .aif .aac · logo: .png")
        }
        notices = newNotices
    }

    /// Removes a clip from the library (and the reel).
    public func removeClip(_ url: URL) {
        clipURLs.removeAll { $0 == url }
        clips.removeAll { $0.url == url }
        excluded.remove(url)
        inPoints[url] = nil
        reframes[url] = nil
        beatCounts[url] = nil
        if selectedClip == url { selectedClip = nil }
    }

    /// Takes the song out (no beats, no cuts until another is dropped).
    public func removeSong() {
        beats.close()
        songURL = nil
        song = nil
    }

    /// Takes the logo out (and stops remembering it).
    public func removeLogo() {
        logoURL = nil
        logo = nil
        defaults.removeObject(forKey: "logoPath")
    }

    /// Starts a new reel: forgets the clips, the song and the logo; keeps the settings.
    public func clear() {
        removeLogo()
        beats.stop()
        clipURLs = []
        clips = []
        excluded = []
        inPoints = [:]
        reframes = [:]
        beatCounts = [:]
        songURL = nil
        song = nil
        selectedClip = nil
        notices = []
        beats.close()
        clearUndo()
    }

    /// Loads whatever was dropped and isn't loaded yet: the logo, the song and its beats, new clips
    /// (added at the end of the reel in capture order), and their preview copies.
    public func refresh() async {
        if loading { refreshAgain = true; return }
        loading = true
        recording = false
        let songBefore = song?.url
        defer {
            recording = true
            if song?.url != songBefore { clearUndo() } else { settle() }
            loading = false
            loadingStatus = ""
            if refreshAgain { refreshAgain = false; Task { await refresh() } }
        }
        if let l = logoURL, logo?.url != l {
            do {
                logo = try MediaProbe.logo(l)
                defaults.set(l.path, forKey: "logoPath")
            } catch {
                notices.append("\(error)")
                logoURL = logo?.url
            }
        }
        if let s = songURL, song?.url != s {
            loadingStatus = "Finding the beats…"
            loadingProgress = 0
            do {
                let info = try await MediaProbe.song(s)
                await beats.open(s)
                if beats.songURL == s { song = info } else { throw MediaError.unsupported(beats.message ?? "Couldn't read \(s.lastPathComponent).") }
            } catch {
                notices.append("\(error)")
                songURL = song?.url
            }
        }
        let known = Set(clips.map(\.url))
        let new = clipURLs.filter { !known.contains($0) }
        if !new.isEmpty {
            loadingStatus = "Reading \(new.count) clip\(new.count == 1 ? "" : "s")…"
            var infos: [ClipInfo] = []
            var unreadable: [URL] = []
            for (i, u) in new.enumerated() {
                loadingProgress = Double(i) / Double(new.count)
                do { infos.append(try await MediaProbe.clip(u)) } catch { unreadable.append(u) }
            }
            clips += sortedByCaptureTime(infos)
            if !unreadable.isEmpty {
                clipURLs.removeAll { unreadable.contains($0) }
                notices.append("Couldn't read, left out: \(unreadable.map(\.lastPathComponent).joined(separator: ", "))")
            }
        }
        let todo = clips.filter { !$0.isPlaceholder && proxies[$0.url] == nil }.map(\.url)
        if !todo.isEmpty {
            var done = 0
            loadingProgress = 0
            loadingStatus = "Making preview copies… 0 of \(todo.count)"
            await withTaskGroup(of: (URL, URL?).self) { group in
                var it = todo.makeIterator()
                for _ in 0..<min(3, todo.count) { if let u = it.next() { group.addTask { (u, try? await Proxies.make(for: u)) } } }
                while let (u, p) = await group.next() {
                    if let p { proxies[u] = p }
                    done += 1
                    loadingProgress = Double(done) / Double(todo.count)
                    loadingStatus = "Making preview copies… \(done) of \(todo.count)"
                    if let n = it.next() { group.addTask { (n, try? await Proxies.make(for: n)) } }
                }
            }
        }
        if selectedClip == nil {
            selectedClip = plan.slots.first.map { reelClips[$0.clipIndex].url } ?? clips.first { !$0.isPlaceholder }?.url
        }
    }

    /// The same as dropping these files and waiting for them to load (scripts and launch arguments).
    public func continueToEditor() async { await refresh() }

    // MARK: The edit

    public var plan: ReelPlan {
        guard let song else { return EditPlanner.plan(clips: [], beats: [], songDuration: 0, settings: settings) }
        var wanted: [Int: Double] = [:]
        let reel = reelClips
        var counts: [Int: Int] = [:]
        for (i, c) in reel.enumerated() {
            if let w = inPoints[c.url] { wanted[i] = w }
            if let n = beatCounts[c.url] { counts[i] = n }
        }
        return EditPlanner.plan(clips: reel, beats: beats.beats.times, songDuration: song.duration.seconds,
                                settings: settings, inPoints: wanted, beatCounts: counts)
    }

    public func moveClips(from: IndexSet, to: Int) { clips.move(fromOffsets: from, toOffset: to) }

    /// Puts `url` just before `target` in the reel order (nil: right after the last clip that's in the reel),
    /// and back in the reel if it was left out.
    public func move(_ url: URL, before target: URL?) {
        guard url != target, let from = clips.firstIndex(where: { $0.url == url }) else { return }
        excluded.remove(url)
        let lastPlaced = plan.slots.last.map { reelClips[$0.clipIndex].url }
        let c = clips.remove(at: from)
        var to: Int
        if let t = target, let i = clips.firstIndex(where: { $0.url == t }) {
            to = i
        } else if let l = lastPlaced, l != url, let i = clips.firstIndex(where: { $0.url == l }) {
            to = i + 1
        } else {
            to = from
        }
        clips.insert(c, at: min(max(0, to), clips.count))
    }

    /// Puts `url` (from the library) into the reel just before `target` (nil: after the last cut). The cuts
    /// after it move along by one; the first empty slot after it closes, so the cuts beyond that stay where
    /// they are. With no empty slot, the last cut that no longer fits the song spills off the end.
    public func insert(_ url: URL, before target: URL?) {
        guard url != target, let from = clips.firstIndex(where: { $0.url == url }), !clips[from].isPlaceholder else { return }
        let before = clips
        let lastPlaced = plan.slots.last.map { reelClips[$0.clipIndex].url }
        var list = clips
        let c = list.remove(at: from)
        let to: Int
        if let t = target, let i = list.firstIndex(where: { $0.url == t }) {
            to = i
        } else if let l = lastPlaced, l != url, let i = list.firstIndex(where: { $0.url == l }) {
            to = i + 1
        } else {
            to = list.count
        }
        list.insert(c, at: to)
        // The first empty slot after it takes up the shift.
        if let g = list[(to + 1)...].firstIndex(where: { $0.isPlaceholder && !excluded.contains($0.url) }) {
            beatCounts[list[g].url] = nil
            list.remove(at: g)
        }
        if list.map(\.url) != before.map(\.url) { clips = list }
        excluded.remove(url)
        selectedClip = url
    }

    /// Tests: these clips, as if dropped and loaded (no undo step).
    func setClipsForTesting(_ list: [ClipInfo], excluded out: Set<URL> = []) {
        recording = false
        clips = list
        excluded = out
        recording = true
        clearUndo()
    }

    /// Clips in the reel that don't fit the song (after the last cut, shown greyed on the timeline).
    public func spilled(_ plan: ReelPlan) -> [ClipInfo] {
        let reel = reelClips
        let last = plan.slots.last?.clipIndex ?? -1
        return reel.indices.filter { $0 > last && !reel[$0].isPlaceholder }.map { reel[$0] }
    }

    /// Takes a cut out of the reel and leaves an empty slot of the same length in its place
    /// (the clip goes back to the library). An empty slot is removed, closing the gap.
    public func removeFromReel(_ url: URL) {
        guard let i = clips.firstIndex(where: { $0.url == url }) else { return }
        if clips[i].isPlaceholder {
            clips.remove(at: i)
            beatCounts[url] = nil
            selectedClip = nil
            return
        }
        guard let s = slot(for: url, in: plan) else { return }
        let gap = ClipInfo.placeholder()
        clips.insert(gap, at: i)
        beatCounts[gap.url] = s.beats
        excluded.insert(url)
        selectedClip = gap.url
    }

    /// Replaces the cut `target` with `url` in the same place and for the same number of beats; `target`
    /// goes back to the library (left out). If `url` was in the reel elsewhere, that spot becomes an empty slot.
    public func replace(_ target: URL, with url: URL) {
        guard url != target, let ti = clips.firstIndex(where: { $0.url == target }), !clips[ti].isPlaceholder,
              clips.contains(where: { $0.url == url && !$0.isPlaceholder }),
              let s = slot(for: target, in: plan) else { return }
        let replaced = clips[ti]
        let gap = ClipInfo.placeholder()
        beatCounts[gap.url] = beatCounts[target] ?? s.beats
        beatCounts[target] = nil
        clips[ti] = gap
        clips.append(replaced)
        excluded.insert(target)
        fill(gap.url, with: url)
    }

    /// Puts `url` into the empty slot `gap` (keeping the slot's length). Dragged from the timeline, the
    /// spot it left becomes an empty slot in turn; from the library, it just moves there.
    public func fill(_ gap: URL, with url: URL) {
        guard url != gap, let gi = clips.firstIndex(where: { $0.url == gap }), clips[gi].isPlaceholder,
              let ci = clips.firstIndex(where: { $0.url == url }), !clips[ci].isPlaceholder else { return }
        let length = beatCounts[gap]
        let clip = clips[ci]
        if !excluded.contains(url), let s = slot(for: url, in: plan) {
            let hole = ClipInfo.placeholder()
            beatCounts[hole.url] = s.beats
            clips[ci] = hole
        } else {
            clips.remove(at: ci)
        }
        if let at = clips.firstIndex(where: { $0.url == gap }) { clips[at] = clip }
        excluded.remove(url)
        beatCounts[gap] = nil
        if let length { beatCounts[url] = length }
        selectedClip = url
    }

    public func setLeftOut(_ url: URL, _ out: Bool) {
        if out { excluded.insert(url) } else { excluded.remove(url) }
    }
    public func slot(for url: URL, in plan: ReelPlan) -> Slot? {
        guard let i = reelClips.firstIndex(where: { $0.url == url }) else { return nil }
        return plan.slots.first { $0.clipIndex == i }
    }

    public func reframe(for clip: ClipInfo) -> Reframe {
        (reframes[clip.url] ?? .centred).clamped(w: Double(clip.width), h: Double(clip.height))
    }

    public var projectName: String {
        guard let first = clipURLs.first else { return "Reel" }
        let folder = first.deletingLastPathComponent()
        // "…/Main Street 1/Clips" → "Main Street 1"
        return folder.lastPathComponent.lowercased() == "clips" ? folder.deletingLastPathComponent().lastPathComponent : folder.lastPathComponent
    }

    /// Default place for the FCPXML: the shoot folder (the one holding the clips folder, if it's called Clips).
    public var exportFolder: URL {
        guard let first = clipURLs.first else { return FileManager.default.homeDirectoryForCurrentUser }
        let folder = first.deletingLastPathComponent()
        return folder.lastPathComponent.lowercased() == "clips" ? folder.deletingLastPathComponent() : folder
    }

    // MARK: Export

    /// The reel as a timeline (cuts, framing, logo, song), for the FCPXML or the video render. `forFinalCut`
    /// hands files with "%" in their names over as clean-named links (Final Cut freezes on them).
    func timeline(name: String, forFinalCut: Bool) throws -> FCPTimeline? {
        guard var song else { return nil }
        let plan = self.plan
        guard !plan.slots.isEmpty else { return nil }
        let reel = reelClips
        var exportClips = reel
        var logoOpt = logo
        if forFinalCut { _ = try ReelExporter.prepareMedia(clips: &exportClips, song: &song, logo: &logoOpt) }
        var transforms: [Int: FCPTransform] = [:]
        for (i, c) in reel.enumerated() { transforms[i] = reframe(for: c).fcpTransform(w: Double(c.width), h: Double(c.height)) }
        return ReelTimelineBuilder.timeline(plan: plan, clips: exportClips, song: song, logo: logoOpt,
                                            settings: settings, projectName: name, transforms: transforms)
    }

    /// Progress of a video render (0...1), nil when none is running.
    public var renderProgress: Double?

    /// Renders the reel to a video file (no stabilization or grading) and shows it in the Finder.
    public func renderVideo(to url: URL) async {
        guard renderProgress == nil else { return }
        do {
            guard let timeline = try timeline(name: url.deletingPathExtension().lastPathComponent, forFinalCut: false) else {
                exportMessage = "No cuts to export."
                return
            }
            renderProgress = 0
            exportMessage = nil
            let start = Date()
            try await ReelRenderer.render(timeline, to: url) { p in
                Task { @MainActor in if self.renderProgress != nil { self.renderProgress = p } }
            }
            renderProgress = nil
            exportMessage = String(format: "Wrote %@ in %.0f s.", url.lastPathComponent, Date().timeIntervalSince(start))
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } catch {
            renderProgress = nil
            exportMessage = "Export failed: \(error)"
        }
    }

    /// Writes the reel for `editor` (the chosen one by default) to `url` and opens it there: FCPXML for
    /// Final Cut Pro, Final Cut Pro 7 XML for Premiere Pro and DaVinci Resolve.
    public func export(to url: URL, editor: Editor? = nil, open: Bool = true) {
        let editor = editor ?? self.editor
        do {
            guard var timeline = try timeline(name: url.deletingPathExtension().lastPathComponent,
                                              forFinalCut: editor == .finalCut) else {
                exportMessage = "No cuts to export."
                return
            }
            if editor == .finalCut {
                if let p = defaults.string(forKey: "libraryPath"), FileManager.default.fileExists(atPath: p) {
                    timeline.libraryLocation = URL(fileURLWithPath: p)
                } else {
                    timeline.libraryLocation = ReelExporter.mostRecentLibrary()
                }
            }
            try ReelExporter.write(timeline, to: url, for: editor)
            guard open else { exportMessage = "Wrote \(url.lastPathComponent)."; return }
            var done = try ReelExporter.open(url, in: editor)
            if editor == .finalCut, editor.installedApp != nil, let l = timeline.libraryLocation {
                done += " into the library \(l.deletingPathExtension().lastPathComponent)"
            }
            exportMessage = "Wrote \(url.lastPathComponent) and \(done)."
        } catch {
            exportMessage = "Export failed: \(error)"
        }
    }
}
