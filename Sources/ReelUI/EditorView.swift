import AppKit
import SwiftUI
import UniformTypeIdentifiers
import FCPXMLKit
import ReelCore
import ReelMedia

/// The editor: the clip library on the left; the reel's cuts on top (drag to arrange), the selected cut's
/// filmstrip, the beats at the bottom; the 9:16 preview on the right, full height.
public struct EditorView: View {
    @Bindable var project: ReelProject
    @State private var cutPlayer = CutPlayer()
    @State private var thumbs = ThumbnailStore()
    @State private var dropTarget: String?
    @State private var confirmClear = false
    @State private var libraryDropTargeted = false
    /// The preview shows the cut under the playhead (after playing or seeking) instead of the selected cut.
    @State private var followingPlayhead = false
    @State private var playheadClip: URL?
    /// The plan as last drawn, for following the playhead without working it out again every frame.
    @State private var planCache = PlanCache()
    @State private var edgeDrag: (url: URL, startBeat: Int)?
    @State private var windowDrop = false
    @State private var keyMonitor: Any?
    @AppStorage("libraryWidth") private var libraryWidth = 310.0
    /// 0 until the user drags it: then a quarter of the window.
    @AppStorage("previewWidth") private var previewWidth = 0.0
    @State private var dividerDragStart: Double?
    @State private var logoDrag: Int64?
    @State private var logoTileTargeted = false
    @State private var songTileTargeted = false

    public init(project: ReelProject) { self.project = project }

    public var body: some View {
        let plan = project.plan
        let _ = planCache.plan = plan
        let cut = project.selectedClip.flatMap { url in
            project.clips.first { $0.url == url }.map { CutContext(clip: $0, slot: project.slot(for: url, in: plan), plan: plan) }
        }
        GeometryReader { geo in
        // Library | editor | preview, with draggable dividers; the widths are kept (and remembered), so
        // nothing resets them when the content changes (SwiftUI's split view did, 2026-11-10).
        let total = geo.size.width
        let lib = min(max(libraryWidth, 170), 420)
        let prev = min(max(previewWidth > 0 ? previewWidth : total * 0.25, 300), max(300, total - lib - 640))
        HStack(spacing: 0) {
            library(plan).frame(width: lib)
            paneDivider { dx in libraryWidth = min(max(lib + dx, 170), 420) }
            VStack(spacing: 0) {
                settingsBar(plan)
                Divider()
                if let cut, cut.clip.isPlaceholder {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Empty slot").font(.title3.weight(.semibold))
                        Text("\(cut.slot?.beats ?? 0) beats. Drop a clip on it in the timeline, from the library or from another cut (which then leaves an empty slot), or press ⌫ to remove it.")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    .padding(14).frame(maxWidth: .infinity, alignment: .leading)
                } else if let cut {
                    CutDetailView(project: project, cut: cut, cutPlayer: cutPlayer)
                } else if project.clips.isEmpty {
                    VStack(spacing: 10) {
                        Image(systemName: "square.and.arrow.down.on.square").font(.system(size: 44, weight: .light)).foregroundStyle(.secondary)
                        Text("Drop the clips, the song and the logo anywhere in the window").font(.title3)
                        Text(checklist).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity).padding(.top, 60)
                } else {
                    Text("Select a clip or a cut").foregroundStyle(.secondary).padding(20)
                }
                Spacer(minLength: 0)
                Divider()
                BeatEditorView(model: project.beats, allowsOpen: false, topLaneHeight: 202,
                               extraWidth: 50 + Double(min(project.spilled(plan).count, Self.spillShown) * 58), controlsBelow: true,
                               onDeleteWithoutBeats: { deleteSelection(plan) }) { pps in
                    AnyView(videoLane(plan, pps: pps))
                }
                .frame(height: 414)
            }
            .frame(minWidth: 640, maxWidth: .infinity)
            paneDivider { dx in previewWidth = min(max(prev - dx, 300), max(300, total - lib - 640)) }
            Group {
                if let shown = followingPlayhead ? playheadCut(plan) ?? cut : cut, shown.clip.isPlaceholder {
                    GeometryReader { geo in
                        let w = max(120, min(geo.size.width - 8, (geo.size.height - 8) * 9 / 16))
                        Color.black.frame(width: w, height: w * 16 / 9)
                            .overlay(Text("Empty slot").foregroundStyle(.secondary))
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                    .padding(12)
                } else if let shown = followingPlayhead ? playheadCut(plan) ?? cut : cut {
                    CutPreviewView(project: project, cut: shown, cutPlayer: cutPlayer)
                } else {
                    Color.clear
                }
            }
            .frame(width: prev)
            .frame(maxHeight: .infinity)
            .background(Color(nsColor: .underPageBackgroundColor))
        }
        }
        .onAppear {
            installKeyMonitor()
            // Not .onChange(of: playhead): reading the playhead here would redraw the whole editor every frame.
            let view = self
            project.beats.onPlayheadMove = { view.followPlayhead(view.planCache.plan ?? view.project.plan) }
            cutPlayer.zoomEffect = { proxy in view.zoomEffect(proxy) }
            cutPlayer.refreshZoom()
        }
        .onDisappear { if let m = keyMonitor { NSEvent.removeMonitor(m); keyMonitor = nil } }
        .onDrop(of: [.fileURL], isTargeted: $windowDrop) { providers in
            Task { @MainActor in await project.drop(await urls(from: providers)) }
            return true
        }
        .overlay {
            if windowDrop {
                RoundedRectangle(cornerRadius: 12).strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 3, dash: [10, 6]))
                    .padding(6).allowsHitTesting(false)
            }
        }
        .overlay(alignment: .top) {
            if !project.notices.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(project.notices, id: \.self) { Label($0, systemImage: "exclamationmark.triangle").font(.callout) }
                }
                .padding(10)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                .padding(.top, 54)
                .onTapGesture { project.notices = [] }
                .help("Click to dismiss")
            }
        }
        .task(id: project.selectedClip) {
            followingPlayhead = false
            cutPlayer.endReel()
            loadPlayer(cut)
        }
        .onChange(of: cut?.inOffset) { if !followingPlayhead { syncWindow(cut) } }
        .onChange(of: cut?.neededSeconds) { if !followingPlayhead { syncWindow(cut) } }
        .onChange(of: project.beats.playing) { followPlayhead(plan) }
    }

    var checklist: String {
        let clips = project.clips.filter { !$0.isPlaceholder }.count
        return [clips > 0 ? "Clips: \(clips) ✓" : "Clips", project.songURL != nil ? "Song ✓" : "Song",
                project.logoURL != nil ? "Logo ✓" : "Logo"].joined(separator: "   ·   ")
    }

    /// ⌫ anywhere in the window (wherever the focus is, but not while typing in a text field).
    func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        let project = self.project
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            // 51: Delete (backspace), 117: Forward Delete. No modifiers.
            guard [51, 117].contains(event.keyCode),
                  event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty,
                  let window = event.window, window.isKeyWindow, !(window is NSPanel),
                  !(window.firstResponder is NSText) else { return event }
            MainActor.assumeIsolated { self.deleteSelection(project.plan) }
            return nil
        }
    }

    /// ⌫: deletes the selected beats if any; otherwise takes the selected cut out of the reel, leaving an
    /// empty slot (or removes a selected empty slot).
    func deleteSelection(_ plan: ReelPlan) {
        if !project.beats.beats.selection.isEmpty {
            project.beats.beats.deleteSelected()
        } else if let url = project.selectedClip, project.slot(for: url, in: plan) != nil {
            cutPlayer.stop()
            project.removeFromReel(url)
        }
    }

    /// Seconds on the reel at the song's playhead.
    func reelTime(_ plan: ReelPlan) -> Double {
        project.beats.playhead - (plan.frameDuration * plan.songInFrames).seconds
    }

    func slotAt(_ plan: ReelPlan, _ t: Double) -> (Int, Slot)? {
        let fd = plan.frameDuration
        return plan.slots.enumerated().first { _, s in t >= (fd * s.startFrame).seconds && t < (fd * s.endFrame).seconds }
    }

    func playheadCut(_ plan: ReelPlan) -> CutContext? {
        guard let url = playheadClip, let c = project.clips.first(where: { $0.url == url }) else { return nil }
        return CutContext(clip: c, slot: project.slot(for: url, in: plan), plan: plan)
    }

    /// Shows the reel's frame at the playhead in the preview (playing along at the cut's speed).
    func followPlayhead(_ plan: ReelPlan) {
        let t = reelTime(plan)
        guard let (n, s) = slotAt(plan, t) else {
            if !project.beats.playing { cutPlayer.endReel() }
            return
        }
        let c = project.reelClips[s.clipIndex]
        if !followingPlayhead { followingPlayhead = true }
        if playheadClip != c.url { playheadClip = c.url }
        guard let proxy = project.proxies[c.url] else { cutPlayer.endReel(); return }
        let src = (s.sourceIn - c.start).seconds + (t - (plan.frameDuration * s.startFrame).seconds) * s.speed.seconds
        // The next cut, so the preview can have it ready.
        var next: (proxy: URL, slot: Int, time: Double, rate: Float)?
        if n + 1 < plan.slots.count {
            let ns = plan.slots[n + 1], nc = project.reelClips[ns.clipIndex]
            if let np = project.proxies[nc.url] { next = (np, n + 1, (ns.sourceIn - nc.start).seconds, Float(ns.speed.seconds)) }
        }
        cutPlayer.followReel(proxy: proxy, slot: n, time: src, rate: Float(s.speed.seconds), playing: project.beats.playing,
                             next: next)
    }

    /// The zoom effect of the cut a proxy belongs to, in the proxy's time.
    func zoomEffect(_ proxy: URL) -> PushAnimation? {
        guard let url = project.proxies.first(where: { $0.value == proxy })?.key,
              let c = project.clips.first(where: { $0.url == url }) else { return nil }
        let plan = planCache.plan ?? project.plan
        let cut = CutContext(clip: c, slot: project.slot(for: url, in: plan), plan: plan)
        let r = project.reframe(for: c)
        guard r.push != 0, cut.neededSeconds > 0 else { return nil }
        return PushAnimation(start: cut.inOffset, duration: cut.neededSeconds, from: r.pushScale(at: 0), to: r.pushScale(at: 1))
    }

    func loadPlayer(_ cut: CutContext?) {
        guard let cut, let proxy = project.proxies[cut.clip.url] else { cutPlayer.stop(); return }
        cutPlayer.load(proxy)
        syncWindow(cut)
    }

    func syncWindow(_ cut: CutContext?) {
        guard let cut else { return }
        cutPlayer.setWindow(start: cut.inOffset, end: cut.inOffset + cut.neededSeconds, rate: cut.rate)
    }

    /// A thin divider between panes; drag it to resize (`resize` gets the drag's distance from its start).
    func paneDivider(resize: @escaping (Double) -> Void) -> some View {
        Rectangle()
            .fill(Color(nsColor: .separatorColor))
            .frame(width: 1)
            .padding(.horizontal, 3)
            .contentShape(Rectangle())
            .onHover { inside in if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() } }
            .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .global)
                .onChanged { g in
                    // Apply only the change since the last event: resize() works from the current width.
                    let last = dividerDragStart ?? 0
                    resize(g.translation.width - last)
                    dividerDragStart = g.translation.width
                }
                .onEnded { _ in dividerDragStart = nil })
    }

    // MARK: Library

    /// All clips as a compact grid: the badge is the clip's cut in the reel; faded ones aren't in it.
    /// Drag a clip onto the strip at the top to put it in the reel there; drag a cut back here to leave it out.
    func library(_ plan: ReelPlan) -> some View {
        let reel = project.reelClips
        var cutOf: [URL: Int] = [:]
        for (n, s) in plan.slots.enumerated() { cutOf[reel[s.clipIndex].url] = n + 1 }
        return VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Library").font(.headline)
                Spacer()
                Text("\(cutOf.keys.filter(\.isFileURL).count) of \(project.clips.filter { !$0.isPlaceholder }.count) used")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 10).padding(.vertical, 8)
            if project.clips.isEmpty {
                Text("Drop clips anywhere in the window.").font(.callout).foregroundStyle(.secondary).padding(10)
            }
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 70, maximum: 110), spacing: 6)], spacing: 8) {
                    ForEach(project.clips.filter { !$0.isPlaceholder }, id: \.url) { c in
                        libraryItem(c, cut: cutOf[c.url])
                    }
                }
                .padding(.horizontal, 8).padding(.bottom, 8)
            }
            .background(libraryDropTargeted ? Color.accentColor.opacity(0.12) : .clear)
            .dropDestination(for: String.self) { items, _ in
                for p in items { project.setLeftOut(dragURL(p), true) }
                return !items.isEmpty
            } isTargeted: { libraryDropTargeted = $0 }
            Text("Drag clips onto the timeline to place them; drag a cut here to leave it out.")
                .font(.caption).foregroundStyle(.secondary).padding(.horizontal, 8).padding(.vertical, 4)
            Divider()
            // Logo and song: always here at the bottom; drop on them to replace.
            HStack(spacing: 8) {
                logoTile
                songTile
            }
            .padding(8)
        }
    }

    var logoTile: some View {
        mediaTile(title: "Logo", targeted: logoTileTargeted, filled: project.logo != nil) {
            if let u = project.logo?.url, let img = NSImage(contentsOf: u) {
                Image(nsImage: img).resizable().scaledToFit().padding(8)
                    .background(Color.black.opacity(0.35))
            }
        } caption: {
            project.logo?.name ?? "Drop a PNG"
        }
        .onDrop(of: [.fileURL], isTargeted: $logoTileTargeted) { providers in
            Task { @MainActor in
                let png = await urls(from: providers).filter { MediaTypes.kind(of: $0) == .logo }
                if !png.isEmpty { await project.drop([png[0]]) } else { project.notices = ["The logo must be a PNG."] }
            }
            return true
        }
        .contextMenu { Button("Remove Logo") { project.removeLogo() }.disabled(project.logo == nil) }
        .help("The logo: drop a PNG here to replace it")
    }

    var songTile: some View {
        mediaTile(title: "Song", targeted: songTileTargeted, filled: project.song != nil) {
            if project.song != nil {
                VStack(spacing: 4) {
                    Image(systemName: "waveform").font(.title2)
                    if let bpm = project.beats.beats.bpm { Text(String(format: "%.0f BPM", bpm)).font(.caption2) }
                }
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.black.opacity(0.35))
            }
        } caption: {
            project.song.map { $0.name + String(format: " · %.0f s", $0.duration.seconds) } ?? "Drop a song"
        }
        .onDrop(of: [.fileURL], isTargeted: $songTileTargeted) { providers in
            Task { @MainActor in
                let audio = await urls(from: providers).filter { MediaTypes.kind(of: $0) == .audio }
                if !audio.isEmpty { await project.drop([audio[0]]) } else { project.notices = ["That isn't a song file (.mp3 .m4a .wav .aif .aac)."] }
            }
            return true
        }
        .contextMenu { Button("Remove Song") { project.removeSong() }.disabled(project.song == nil) }
        .help("The song: drop an audio file here to replace it")
    }

    func mediaTile<C: View>(title: String, targeted: Bool, filled: Bool, @ViewBuilder content: () -> C,
                            caption: () -> String) -> some View {
        VStack(spacing: 3) {
            ZStack {
                if filled {
                    content()
                } else {
                    Text(title).font(.caption).foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 64)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6)
                .strokeBorder(style: StrokeStyle(lineWidth: targeted ? 2.5 : 1.2, dash: filled && !targeted ? [] : [5, 4]))
                .foregroundStyle(targeted ? Color.accentColor : Color.secondary.opacity(filled ? 0.3 : 0.6)))
            Text(caption()).font(.system(size: 9)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
        }
        .frame(maxWidth: .infinity)
    }

    func libraryItem(_ c: ClipInfo, cut: Int?) -> some View {
        let selected = project.selectedClip == c.url
        let left = project.excluded.contains(c.url)
        return VStack(spacing: 2) {
            Thumb(image: thumbs.image(project.proxies[c.url], at: c.duration.seconds / 2))
                .frame(height: 92)
                .clipShape(RoundedRectangle(cornerRadius: 5))
                .overlay(alignment: .topLeading) {
                    if let cut {
                        Text("\(cut)").font(.caption2.bold()).foregroundStyle(.white)
                            .padding(.horizontal, 4).padding(.vertical, 1)
                            .background(Color.accentColor, in: Capsule()).padding(3)
                    }
                }
                .overlay(alignment: .topTrailing) {
                    if left {
                        Image(systemName: "eye.slash").font(.caption2).foregroundStyle(.white).padding(3)
                            .background(.black.opacity(0.6), in: Circle()).padding(3)
                    } else if cut == nil {
                        Image(systemName: "minus.circle.fill").font(.caption2).foregroundStyle(.orange).padding(3)
                            .help("Not in the reel: the song has no room for it")
                    }
                }
                .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(selected ? Color.accentColor : .clear, lineWidth: 2.5))
                .opacity(cut == nil ? 0.5 : 1)
            Text(c.name).font(.system(size: 9)).lineLimit(1).foregroundStyle(.secondary)
            Text(String(format: "%.1f s%@", c.duration.seconds, c.speed == RationalTime(1) ? "" : " · 50 %"))
                .font(.system(size: 9)).foregroundStyle(.tertiary)
        }
        .contentShape(Rectangle())
        .onTapGesture { project.beats.beats.selection = []; project.selectedClip = c.url }
        .draggable(libraryDragPrefix + c.url.path) {
            Thumb(image: thumbs.image(project.proxies[c.url], at: c.duration.seconds / 2)).frame(width: 54, height: 92)
        }
        .contextMenu {
            if left {
                Button("Put Back in the Reel") { project.setLeftOut(c.url, false) }
            } else {
                Button("Leave Out of the Reel") { project.setLeftOut(c.url, true) }
            }
            Divider()
            Button("Remove from Library") { project.removeClip(c.url) }
        }
        .help(left ? "Left out of the reel (right-click to put it back)" : "Drag onto the timeline to place it")
    }

    // MARK: Settings and export

    func settingsBar(_ plan: ReelPlan) -> some View {
        HStack(spacing: 14) {
            Button { project.beats.togglePlay() } label: {
                Label(project.beats.playing ? "Stop" : "Play", systemImage: project.beats.playing ? "stop.fill" : "play.fill")
                    .fixedSize()
            }
            .keyboardShortcut(.space, modifiers: [])
            .help("Play the reel with the song; the preview follows (space)")
            Stepper(value: $project.settings.beatsPerCut, in: 1...16) {
                Text(project.settings.fixedCuts ? "Every \(project.settings.beatsPerCut) beats" : "Up to \(project.settings.beatsPerCut) beats")
                    .fixedSize()
            }
            .help("Longest cut in beats")
            if !project.settings.fixedCuts {
                Stepper(value: $project.settings.minCutLength, in: 0.3...4, step: 0.1) {
                    Text(String(format: "min %.1f s", project.settings.minCutLength)).fixedSize()
                }
                .help("Shortest cut, in seconds")
            }
            Toggle("Fixed", isOn: $project.settings.fixedCuts).toggleStyle(.checkbox).fixedSize()
                .help("Every cut exactly that many beats (clips that don't fit are left out)")
            Button { confirmClear = true } label: { Label("Clear All", systemImage: "trash").fixedSize() }
                .help("Start over: take out the clips, the song and the logo (settings stay)")
                .disabled(project.clips.isEmpty && project.songURL == nil && project.logoURL == nil)
                .confirmationDialog("Clear the reel and start over?", isPresented: $confirmClear) {
                    Button("Clear All", role: .destructive) { cutPlayer.stop(); project.clear() }
                } message: { Text("The clips, the song and the logo are taken out. Your files are not touched.") }
            Spacer()
            if project.loading {
                ProgressView(value: project.loadingProgress).frame(width: 80)
                Text(project.loadingStatus).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Text(String(format: "%d cuts · %.1f s", plan.slots.count, plan.duration.seconds))
                .font(.callout.monospacedDigit()).foregroundStyle(.secondary).fixedSize()
            if let p = project.renderProgress {
                ProgressView(value: p).frame(width: 80)
                Text("Rendering…").font(.caption).foregroundStyle(.secondary).fixedSize()
            }
            Button { videoPanel() } label: { Label("Export Video", systemImage: "film").fixedSize() }
                .help("Render the reel to a video file, ready to post: no stabilization or grading (⇧⌘E)")
                .disabled(plan.slots.isEmpty || project.renderProgress != nil)
                .keyboardShortcut("e", modifiers: [.command, .shift])
            Menu {
                Picker("Editor", selection: $project.editor) {
                    ForEach(Editor.allCases) { e in
                        Text(e.installedApp == nil ? "\(e.name) (not installed)" : e.name).tag(e)
                    }
                }
                .pickerStyle(.inline)
            } label: {
                Label("Open in Editor", systemImage: "square.and.arrow.up").fixedSize()
            } primaryAction: {
                exportPanel()
            }
            .menuStyle(.borderedButton)
            .fixedSize()
            .help("Write the project and open it in \(project.editor.name), to stabilize, grade and finish there (⌘E). "
                  + "The arrow picks the editor.")
            .disabled(plan.slots.isEmpty || project.logo == nil && project.logoURL == nil)
            .background {
                // ⌘E for the split button's main action (a Menu's own shortcut would open the menu).
                Button("Open in Editor") { exportPanel() }
                    .keyboardShortcut("e")
                    .disabled(plan.slots.isEmpty || project.logo == nil && project.logoURL == nil)
                    .opacity(0).accessibilityHidden(true)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .overlay(alignment: .bottomTrailing) {
            if let m = project.exportMessage {
                Text(m).font(.caption).padding(6).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
                    .offset(y: 30).padding(.trailing, 12).onTapGesture { project.exportMessage = nil }
            }
        }
        .zIndex(1)
    }

    func exportPanel() {
        cutPlayer.stop()
        let p = NSSavePanel()
        let editor = project.editor
        p.allowedContentTypes = [UTType(filenameExtension: editor.fileExtension) ?? .xml]
        p.directoryURL = project.exportFolder
        p.nameFieldStringValue = project.projectName + "." + editor.fileExtension
        p.message = editor.importHint
        if p.runModal() == .OK, let url = p.url { project.export(to: url, editor: editor) }
    }

    func videoPanel() {
        cutPlayer.stop()
        project.beats.stop()
        let p = NSSavePanel()
        p.allowedContentTypes = [.mpeg4Movie, .quickTimeMovie]
        p.directoryURL = project.exportFolder
        p.nameFieldStringValue = project.projectName + ".mp4"
        p.message = "1080×1920 H.264 with the song, ready to post. No stabilization or grading: use your editor for those."
        if p.runModal() == .OK, let url = p.url { Task { await project.renderVideo(to: url) } }
    }

    // MARK: The video track, on the song's time scale above the waveform

    /// The reel's cuts on the same scale as the beats below: drag a cut's right edge to snap it to another
    /// beat (sets its length in beats), drag a cut to reorder, drop library clips onto it.
    func videoLane(_ plan: ReelPlan, pps: Double) -> some View {
        let reel = project.reelClips
        let fd = plan.frameDuration
        let offset = (fd * plan.songInFrames).seconds
        return ZStack(alignment: .topLeading) {
            Color.clear
            ForEach(Array(plan.slots.enumerated()), id: \.offset) { n, s in
                let c = reel[s.clipIndex]
                let x = ((fd * s.startFrame).seconds + offset) * pps
                let w = (fd * (s.endFrame - s.startFrame)).seconds * pps
                let next: URL? = n + 1 < plan.slots.count ? reel[plan.slots[n + 1].clipIndex].url : nil
                Group {
                    if c.isPlaceholder {
                        emptyTile(plan, n: n, slot: s, clip: c, width: max(w - 2, 3), height: 140)
                    } else {
                        cutTile(plan, n: n, slot: s, clip: c, width: max(w - 2, 3), height: 140, next: next)
                    }
                }
                    .overlay(alignment: .trailing) { edgeHandle(plan, slot: s, clip: c, pps: pps, offset: offset) }
                    .offset(x: x, y: 58)
            }
            // End of the reel: drop here to add a clip after the last cut.
            let end = ((fd * plan.totalFrames).seconds + offset) * pps
            RoundedRectangle(cornerRadius: 5)
                .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
                .foregroundStyle(dropTarget == "end" ? Color.accentColor : Color.secondary.opacity(0.5))
                .overlay(Image(systemName: "plus").foregroundStyle(.secondary))
                .frame(width: 30, height: 140)
                .contentShape(Rectangle())
                .dropDestination(for: String.self) { items, _ in
                    for p in items { project.move(dragURL(p), before: nil) }
                    return !items.isEmpty
                } isTargeted: { t in
                    if t { dropTarget = "end" } else if dropTarget == "end" { dropTarget = nil }
                }
                .help("Drop a clip here to add it after the last cut")
                .offset(x: end + 4, y: 58)
            // Clips in the reel that no longer fit the song: greyed, past the end; drag one back in.
            let spill = project.spilled(plan)
            ForEach(Array(spill.prefix(Self.spillShown).enumerated()), id: \.element.url) { k, c in
                spillTile(c, more: k == Self.spillShown - 1 ? spill.count - Self.spillShown : 0)
                    .offset(x: end + 40 + Double(k) * 58, y: 58)
            }
            logoLayer(plan, pps: pps, offset: offset)
            // Top ruler: the playhead handle's track. Click to jump there, drag to scrub.
            Canvas { ctx, size in
                // Seconds on top, then the handle's track with its ticks.
                ctx.fill(Path(CGRect(x: 0, y: 12, width: size.width, height: 13)), with: .color(Color.secondary.opacity(0.14)))
                let every = pps < 40 ? 5 : 1
                var t = 0.0
                while t * pps <= size.width {
                    let x = t * pps, whole = t.truncatingRemainder(dividingBy: 1) == 0
                    ctx.stroke(Path { $0.move(to: CGPoint(x: x, y: whole ? 16 : 21)); $0.addLine(to: CGPoint(x: x, y: 25)) },
                               with: .color(Color.secondary.opacity(whole ? 0.7 : 0.35)), lineWidth: 1)
                    if whole && Int(t) % every == 0 {
                        ctx.draw(Text("\(Int(t)) s").font(.system(size: 9)).foregroundStyle(.secondary),
                                 at: CGPoint(x: x + 2, y: 0), anchor: .topLeading)
                    }
                    t += pps >= 60 ? 0.5 : 1
                }
            }
            .frame(height: 25)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("lane"))
                .onChanged { g in project.beats.seek(to: max(0, g.location.x / pps)) })
            .onHover { inside in if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() } }
            .help("Click to jump here, drag to scrub")
            // Beat lines, continuing those in the waveform up to the top of the timeline.
            Canvas { ctx, size in
                for t in project.beats.beats.times {
                    let x = t * pps
                    ctx.stroke(Path { $0.move(to: CGPoint(x: x, y: 26)); $0.addLine(to: CGPoint(x: x, y: size.height)) },
                               with: .color(Color.accentColor.opacity(0.45)), lineWidth: 1)
                }
            }
            .allowsHitTesting(false)
            // Playhead, continuing the one in the waveform below, with a handle at the top to scrub.
            PlayheadPin(model: project.beats) {
                ZStack(alignment: .top) {
                    Rectangle().fill(Color.red).frame(width: 1.5, height: 190).allowsHitTesting(false)
                    // A square with a point below it, like a pin.
                    Path { p in
                        p.addRoundedRect(in: CGRect(x: 0, y: 0, width: 18, height: 12), cornerSize: CGSize(width: 2.5, height: 2.5))
                        p.move(to: CGPoint(x: 0, y: 11)); p.addLine(to: CGPoint(x: 18, y: 11)); p.addLine(to: CGPoint(x: 9, y: 21))
                        p.closeSubpath()
                    }
                    .fill(Color.red)
                    .frame(width: 18, height: 21)
                    .contentShape(Rectangle().inset(by: -6))
                    .onHover { inside in if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() } }
                    .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("lane"))
                        .onChanged { g in project.beats.seek(to: g.location.x / pps) })
                    .help("Drag to scrub")
                }
                .frame(width: 18)
            } offset: { $0 * pps - 9 }
        }
        .coordinateSpace(name: "lane")
    }

    /// The logo layer: when the intro and outro logos are on screen. Drag the intro's end or the outro's
    /// start to another beat; right-click to switch either off; "+" puts it back.
    @ViewBuilder
    func logoLayer(_ plan: ReelPlan, pps: Double, offset: Double) -> some View {
        let fd = plan.frameDuration
        let grid = plan.beatGrid
        let x = { (f: Int64) in ((fd * f).seconds + offset) * pps }
        let endIdx = grid.firstIndex(of: plan.totalFrames)
        if !plan.slots.isEmpty {
            if let e = plan.introEndFrame {
                logoBar("Intro logo", width: x(e) - x(0), handleAtEnd: true) { loc in
                    let f = Int64(((loc / pps - offset) / fd.seconds).rounded())
                    if let j = grid.indices.filter({ grid[$0] <= plan.totalFrames }).min(by: { abs(grid[$0] - f) < abs(grid[$1] - f) }) {
                        project.settings.introBeats = j + 1
                    }
                } menu: {
                    Button("Intro Logo to the End of the First Cut") { project.settings.introBeats = nil }
                    Button("No Intro Logo") { project.settings.showIntroLogo = false }
                }
                .offset(x: x(0), y: 28)
            } else {
                addLogoButton("Intro logo") { project.settings.showIntroLogo = true }.offset(x: x(0), y: 28)
            }
            if let o = plan.outroStartFrame {
                logoBar("Outro logo", width: x(plan.totalFrames) - x(o), handleAtEnd: false) { loc in
                    let f = Int64(((loc / pps - offset) / fd.seconds).rounded())
                    guard let endIdx, let j = grid.indices.filter({ $0 < endIdx }).min(by: { abs(grid[$0] - f) < abs(grid[$1] - f) }) else { return }
                    project.settings.outroBeats = endIdx - j
                } menu: {
                    Button("Outro Logo from the Start of the Last Cut") { project.settings.outroBeats = nil }
                    Button("No Outro Logo") { project.settings.showOutroLogo = false }
                }
                .offset(x: x(o), y: 28)
            } else {
                addLogoButton("Outro logo") { project.settings.showOutroLogo = true }
                    .offset(x: max(x(0), x(plan.totalFrames) - 90), y: 28)
            }
        }
    }

    func logoBar(_ title: String, width: Double, handleAtEnd: Bool, drag: @escaping (Double) -> Void,
                 @ViewBuilder menu: () -> some View) -> some View {
        RoundedRectangle(cornerRadius: 4)
            .fill(Color.yellow.opacity(0.28))
            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Color.yellow.opacity(0.7), lineWidth: 1))
            .overlay(alignment: .leading) {
                HStack(spacing: 4) {
                    if let u = project.logo?.url, let img = NSImage(contentsOf: u) {
                        Image(nsImage: img).resizable().scaledToFit().frame(height: 14)
                    }
                    Text(title).font(.system(size: 9, weight: .medium)).lineLimit(1)
                }
                .padding(.horizontal, handleAtEnd ? 6 : 12)
            }
            .overlay(alignment: handleAtEnd ? .trailing : .leading) {
                Rectangle().fill(Color.yellow).frame(width: 6)
                    .contentShape(Rectangle().inset(by: -4))
                    .onHover { inside in if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() } }
                    .highPriorityGesture(DragGesture(minimumDistance: 1, coordinateSpace: .named("lane"))
                        .onChanged { g in drag(g.location.x) })
                    .help("Drag to another beat")
            }
            .frame(width: max(width - 2, 8), height: 24)
            .contextMenu { menu() }
    }

    func addLogoButton(_ title: String, add: @escaping () -> Void) -> some View {
        Button(action: add) { Label(title, systemImage: "plus").font(.system(size: 9)) }
            .buttonStyle(.borderless)
            .frame(height: 24)
            .help("Show the \(title.lowercased()) again")
    }

    static let spillShown = 6

    /// A clip that doesn't fit the song: greyed; drag it into the reel, or right-click to leave it out.
    func spillTile(_ c: ClipInfo, more: Int) -> some View {
        let mid = c.duration.seconds / 2
        return Thumb(image: thumbs.image(project.proxies[c.url], at: mid))
            .frame(width: 54, height: 140)
            .saturation(0)
            .opacity(0.4)
            .overlay(alignment: .bottomLeading) {
                VStack(alignment: .leading, spacing: 0) {
                    Text(c.name).font(.system(size: 8)).lineLimit(1)
                    Text(more > 0 ? "+\(more) more" : "Doesn't fit").font(.system(size: 8)).opacity(0.8)
                }
                .foregroundStyle(.secondary).padding(3)
            }
            .clipShape(RoundedRectangle(cornerRadius: 5))
            .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(project.selectedClip == c.url ? Color.accentColor : .clear, lineWidth: 2))
            .contentShape(Rectangle())
            .onTapGesture { project.beats.beats.selection = []; project.selectedClip = c.url }
            .draggable(libraryDragPrefix + c.url.path) {
                Thumb(image: thumbs.image(project.proxies[c.url], at: mid)).frame(width: 54, height: 92)
            }
            .contextMenu { Button("Leave Out of the Reel") { project.setLeftOut(c.url, true) } }
            .help("\(c.name) doesn't fit the song: drag it into the reel (the cuts move along), or leave it out")
    }

    /// The handle on a cut's right edge: drag to a beat; the cut becomes that many beats long.
    func edgeHandle(_ plan: ReelPlan, slot s: Slot, clip c: ClipInfo, pps: Double, offset: Double) -> some View {
        let grid = plan.beatGrid
        return Rectangle()
            .fill(Color.yellow.opacity(edgeDrag?.url == c.url ? 1 : 0.75))
            .frame(width: 6)
            .padding(.vertical, 18)
            .contentShape(Rectangle().inset(by: -4))
            .onHover { inside in if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() } }
            .highPriorityGesture(DragGesture(minimumDistance: 1, coordinateSpace: .named("lane"))
                .onChanged { g in
                    // Beat index the cut starts on (-1: the reel's first frame).
                    let startBeat = edgeDrag?.startBeat ?? (grid.lastIndex { $0 <= s.startFrame } ?? -1)
                    if edgeDrag == nil { edgeDrag = (c.url, startBeat) }
                    let frame = Int64(((g.location.x / pps - offset) / plan.frameDuration.seconds).rounded())
                    // Nearest beat after the cut's start.
                    let candidates = grid.indices.filter { $0 > startBeat }
                    guard let j = candidates.min(by: { abs(grid[$0] - frame) < abs(grid[$1] - frame) }) else { return }
                    let count = j - startBeat
                    if project.beatCounts[c.url] != count { project.beatCounts[c.url] = count }
                }
                .onEnded { _ in edgeDrag = nil })
            .help("Drag to snap this cut's end to another beat")
            .contextMenu {
                Button("Automatic Length") { project.beatCounts[c.url] = nil }
                    .disabled(project.beatCounts[c.url] == nil)
            }
    }

    /// An empty slot: drop a clip on it to fill it (keeping its length).
    func emptyTile(_ plan: ReelPlan, n: Int, slot s: Slot, clip c: ClipInfo, width w: Double, height H: Double) -> some View {
        let selected = project.selectedClip == c.url
        let key = c.url.absoluteString
        return RoundedRectangle(cornerRadius: 5)
            .fill(dropTarget == key ? Color.yellow.opacity(0.25) : Color.secondary.opacity(0.08))
            .overlay(RoundedRectangle(cornerRadius: 5)
                .strokeBorder(style: StrokeStyle(lineWidth: selected ? 2.5 : 1.5, dash: [5, 4]))
                .foregroundStyle(selected ? Color.accentColor : Color.yellow.opacity(0.8)))
            .overlay(alignment: .bottomLeading) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("\(n + 1)").font(.caption2.bold())
                    Text("Empty").font(.system(size: 9))
                    Text("\(s.beats) beat\(s.beats == 1 ? "" : "s")").font(.system(size: 8)).opacity(0.8)
                }
                .foregroundStyle(.secondary).padding(4)
            }
            .overlay { Image(systemName: "plus").foregroundStyle(.yellow.opacity(0.8)) }
            .frame(width: w, height: H)
            .contentShape(Rectangle())
            .onTapGesture { project.beats.beats.selection = []; project.selectedClip = c.url }
            .dropDestination(for: String.self) { items, _ in
                guard let p = items.first else { return false }
                project.fill(c.url, with: dragURL(p))
                return true
            } isTargeted: { t in
                if t { dropTarget = key } else if dropTarget == key { dropTarget = nil }
            }
            .contextMenu { Button("Remove Empty Slot") { project.removeFromReel(c.url) } }
            .help("Empty slot: drop a clip here")
    }

    func cutTile(_ plan: ReelPlan, n: Int, slot s: Slot, clip c: ClipInfo, width w: Double, height H: Double, next: URL?) -> some View {
        let selected = project.selectedClip == c.url
        let need = (plan.frameDuration * (s.endFrame - s.startFrame) * s.speed).seconds
        let mid = (s.sourceIn - c.start).seconds + need / 2
        // The logo is on screen during some of this cut.
        let logo = (plan.introEndFrame.map { s.startFrame < $0 } ?? false) || (plan.outroStartFrame.map { s.endFrame > $0 } ?? false)
        let key = c.url.path
        let fixed = project.beatCounts[c.url] != nil
        return Thumb(image: thumbs.image(project.proxies[c.url], at: mid))
            .frame(width: w, height: H)
            .overlay(LinearGradient(colors: [.clear, .black.opacity(0.7)], startPoint: .center, endPoint: .bottom))
            .overlay(alignment: .bottomLeading) {
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 3) {
                        Text("\(n + 1)").font(.caption2.bold())
                        if logo { Image(systemName: "seal.fill").font(.system(size: 8)).help("Logo on screen") }
                        if fixed { Image(systemName: "pin.fill").font(.system(size: 8)).help("Length set by hand (right-click the edge for automatic)") }
                    }
                    Text(c.name).font(.system(size: 9)).lineLimit(1)
                    Text("\(s.beats) beat\(s.beats == 1 ? "" : "s")").font(.system(size: 8)).opacity(0.8)
                }
                .foregroundStyle(.white).padding(4)
            }
            .clipShape(RoundedRectangle(cornerRadius: 5))
            .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(selected ? Color.accentColor : .clear, lineWidth: 3))
            .overlay(alignment: .leading) {
                if dropTarget == key { Rectangle().fill(Color.accentColor).frame(width: 4).offset(x: -3) }
            }
            .contentShape(Rectangle())
            .onTapGesture { project.beats.beats.selection = []; project.selectedClip = c.url }
            .draggable(c.url.path) {
                Thumb(image: thumbs.image(project.proxies[c.url], at: mid)).frame(width: 54, height: 92)
            }
            .dropDestination(for: String.self) { items, location in
                // Left half of a cut: before it; right half: after it.
                let before = location.x < w / 2 ? c.url : next
                for p in items {
                    if p.hasPrefix(libraryDragPrefix) {
                        // From the library: in between, moving the next cuts along (to an empty slot, if any).
                        project.insert(dragURL(p), before: before)
                    } else {
                        // From the timeline: move it before/after this cut.
                        project.move(dragURL(p), before: before)
                    }
                }
                return !items.isEmpty
            } isTargeted: { t in
                if t { dropTarget = key } else if dropTarget == key { dropTarget = nil }
            }
            .contextMenu {
                Button("Automatic Length") { project.beatCounts[c.url] = nil }.disabled(!fixed)
                Button("Remove, Leaving an Empty Slot") { project.removeFromReel(c.url) }
                Button("Leave Out of the Reel") { project.setLeftOut(c.url, true) }
            }
    }
}

/// Drags from the library carry this before the clip's path (drags of cuts on the timeline don't).
let libraryDragPrefix = "library:"

func dragURL(_ payload: String) -> URL {
    URL(fileURLWithPath: payload.hasPrefix(libraryDragPrefix) ? String(payload.dropFirst(libraryDragPrefix.count)) : payload)
}

/// The app's root: the editor, empty until files are dropped on it.
public struct RootView: View {
    @Bindable var project: ReelProject
    public init(project: ReelProject) { self.project = project }
    public var body: some View {
        EditorView(project: project)
            .task { await project.refresh() }   // the remembered logo
    }
}

/// File URLs from drag-and-drop providers.
@MainActor
func urls(from providers: [NSItemProvider]) async -> [URL] {
    var out: [URL] = []
    for p in providers {
        if let u = await withCheckedContinuation({ (c: CheckedContinuation<URL?, Never>) in
            _ = p.loadObject(ofClass: URL.self) { url, _ in c.resume(returning: url) }
        }) { out.append(u) }
    }
    return out
}

/// The plan as last drawn (a plain box: changing it redraws nothing).
final class PlanCache { var plan: ReelPlan? }

/// The playhead in the video lane: its own view, so only it moves every frame while playing.
struct PlayheadPin<Content: View>: View {
    let model: BeatEditorModel
    @ViewBuilder let content: () -> Content
    let offset: (Double) -> Double
    var body: some View {
        content().offset(x: offset(model.playhead), y: 12)
    }
}
