import AppKit
import SwiftUI
import UniformTypeIdentifiers
import ReelCore
import ReelMedia

/// Waveform with beat lines: listen, tap in beats, select, drag, nudge, delete, save.
public struct BeatEditorView: View {
    @Bindable var model: BeatEditorModel
    /// Draws the whole song without scrolling (for rendering to an image).
    var staticRender: Bool
    /// Show "Open…" (the standalone beat editor); off inside the app, where the song comes from the start screen.
    var allowsOpen: Bool
    /// A lane drawn above the waveform on the same time scale (the app's video track), given pixels per
    /// second of song time, and its height.
    var topLane: ((Double) -> AnyView)?
    var topLaneHeight: Double
    /// Room past the song's end in the top lane (the app shows clips that don't fit there).
    var extraWidth: Double
    /// Put the controls below the waveform (in the app) instead of above it.
    var controlsBelow: Bool
    /// ⌫ with no beats selected (in the app: remove the selected cut).
    var onDeleteWithoutBeats: (() -> Void)?
    @FocusState private var focused: Bool
    @State private var dragging: Int?
    @State private var scrubbing = false
    @State private var zoomAtPinchStart: Double?
    /// The page of the timeline shown while playing zoomed in (it turns a page when the playhead nears the edge).
    @State private var followPage: Int?

    public init(model: BeatEditorModel, staticRender: Bool = false, allowsOpen: Bool = true,
                topLaneHeight: Double = 0, extraWidth: Double = 0, controlsBelow: Bool = false, onDeleteWithoutBeats: (() -> Void)? = nil,
                topLane: ((Double) -> AnyView)? = nil) {
        self.model = model
        self.staticRender = staticRender
        self.allowsOpen = allowsOpen
        self.topLane = topLane
        self.topLaneHeight = topLane == nil ? 0 : topLaneHeight
        self.extraWidth = topLane == nil ? 0 : extraWidth
        self.controlsBelow = controlsBelow
        self.onDeleteWithoutBeats = onDeleteWithoutBeats
    }

    public var body: some View {
        VStack(spacing: 0) {
            if !controlsBelow {
                toolbar
                Divider()
            }
            if model.songURL == nil {
                dropHint
            } else {
                editor
            }
            Divider()
            if controlsBelow {
                toolbar
                Divider()
            }
            footer
        }
        .frame(minWidth: 600, minHeight: 170)
        .background(Color(nsColor: .windowBackgroundColor))
        .onDrop(of: allowsOpen ? [.fileURL] : [], isTargeted: nil) { providers in
            _ = providers.first?.loadObject(ofClass: URL.self) { url, _ in
                if let url { Task { @MainActor in await model.open(url) } }
            }
            return true
        }
    }

    // MARK: Parts

    var toolbar: some View {
        HStack(spacing: 12) {
            if allowsOpen { Button("Open…") { openPanel() }.keyboardShortcut("o") }
            Button(model.playing ? "Pause" : "Play") { model.togglePlay() }
                .disabled(model.songURL == nil)
            Divider().frame(height: 18)
            if model.songURL != nil {
                VStack(alignment: .leading, spacing: 1) {
                    Text(model.title).font(.headline).lineLimit(1)
                    Text(summary).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer()
            Toggle("Snap taps", isOn: $model.snapTaps).toggleStyle(.checkbox)
                .help("T snaps the new beat to the nearest attack in the music (within 80 ms)")
            HStack(spacing: 4) {
                Image(systemName: "minus.magnifyingglass").foregroundStyle(.secondary)
                Slider(value: $model.zoom, in: 1...16).frame(width: 110)
                Image(systemName: "plus.magnifyingglass").foregroundStyle(.secondary)
            }
            Button { model.undo() } label: { Image(systemName: "arrow.uturn.backward") }
                .keyboardShortcut("z")
                .disabled(!model.canUndo)
                .help("Undo (⌘Z): cuts, framing, logo, beats")
            Button { model.redo() } label: { Image(systemName: "arrow.uturn.forward") }
                .keyboardShortcut("z", modifiers: [.command, .shift])
                .disabled(!model.canRedo)
                .help("Redo (⇧⌘Z)")
            Button("Revert") { Task { await model.revert() } }
                .disabled(model.songURL == nil || (model.source != .corrected && !model.dirty))
                .help("Back to the detected beats, forgetting your corrections")
            Button("Save") { model.save() }.keyboardShortcut("s")
                .disabled(!model.dirty)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
    }

    var summary: String {
        var s = "\(model.beats.times.count) beats"
        if let bpm = model.beats.bpm { s += String(format: " · %.1f BPM", bpm) }
        s += " · " + (model.dirty ? "edited, from \(model.basedOn.rawValue)" : model.source.rawValue)
        if !model.beats.selection.isEmpty { s += " · \(model.beats.selection.count) selected" }
        return s
    }

    var dropHint: some View {
        VStack(spacing: 8) {
            Image(systemName: "waveform").font(.system(size: 40)).foregroundStyle(.secondary)
            Text(model.loading ? "Reading the song…" : (allowsOpen ? "Drop a song here, or Open…" : "Drop a song anywhere in the window"))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    var footer: some View {
        HStack {
            Text(model.message ?? "Space play/stop · drag the ruler to scrub · T tap a beat · drag a beat to move · ⌥-click add · ⌫ delete · ←/→ nudge (⇧ one frame) · ⌘Z undo · click left of 0 s or Home: start")
                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            Spacer()
            PlayheadTime(model: model)
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
    }

    var editor: some View {
        GeometryReader { geo in
            let pps = max(20, (geo.size.width - 24) / max(model.duration, 0.1) * model.zoom)
            let width = model.duration * pps
            // Playing zoomed in, the view turns a page when the playhead reaches 90 % of it, putting it at 10 %.
            let visible = max(1, geo.size.width - 24), step = visible * 0.8
            Group {
                if staticRender {
                    canvas(pps: pps, height: geo.size.height).frame(width: width)
                } else {
                    ScrollViewReader { proxy in
                        ScrollView(.horizontal) {
                            VStack(alignment: .leading, spacing: 0) {
                                if let topLane {
                                    topLane(pps).frame(width: width + extraWidth, height: topLaneHeight)
                                }
                                canvas(pps: pps, height: geo.size.height - 16 - topLaneHeight)
                                    .frame(width: width, height: geo.size.height - 16 - topLaneHeight)
                            }
                            .background(alignment: .topLeading) {
                                // Scroll targets, one per page.
                                ZStack(alignment: .topLeading) {
                                    ForEach(0..<(Int(width / step) + 1), id: \.self) { k in
                                        Color.clear.frame(width: 1, height: 1).padding(.leading, Double(k) * step).id("page\(k)")
                                    }
                                }
                            }
                        }
                        .background {
                            // The clock while playing: moves the playhead (only the views that draw it redraw).
                            TimelineView(.animation(paused: !model.playing)) { tl in
                                Color.clear.onChange(of: tl.date) {
                                    model.tick()
                                    let page = Int(model.playhead * pps / step)
                                    if model.playing && model.zoom > 1.05 && page != followPage {
                                        followPage = page
                                        withAnimation(.easeInOut(duration: 0.25)) {
                                            proxy.scrollTo("page\(page)", anchor: UnitPoint(x: 0.1, y: 0))
                                        }
                                    }
                                }
                            }
                        }
                        .onChange(of: model.playing) { followPage = nil }
                        .simultaneousGesture(MagnifyGesture()
                            .onChanged { g in
                                if zoomAtPinchStart == nil { zoomAtPinchStart = model.zoom }
                                model.zoom = min(max(zoomAtPinchStart! * g.magnification, 1), 16)
                            }
                            .onEnded { _ in zoomAtPinchStart = nil })
                    }
                }
            }
            .padding(.horizontal, 12)
            // Left of the timeline: back to the start.
            .overlay(alignment: .leading) {
                Color.clear.frame(width: 12).contentShape(Rectangle())
                    .onTapGesture { model.seek(to: 0) }
                    .help("Back to the start")
            }
        }
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        .onAppear { focused = true }
        .onKeyPress(phases: .down) { press in handleKey(press) }
    }

    func canvas(pps: Double, height: Double) -> some View {
        Canvas { ctx, size in
            draw(ctx, size: size, pps: pps)
        }
        .overlay { PlayheadLine(model: model, pps: pps).allowsHitTesting(false) }
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { g in
                    let t = g.location.x / pps
                    if scrubbing {
                        model.seek(to: t)
                    } else if dragging == nil && g.translation == .zero {
                        if g.startLocation.y < 12 {
                            // The ruler (and the playhead's handle in it): scrub.
                            scrubbing = true
                            model.seek(to: t)
                        } else if let i = model.beats.nearest(to: g.startLocation.x / pps, within: 6 / pps) {
                            if NSEvent.modifierFlags.contains(.shift) {
                                if model.beats.selection.contains(i) { model.beats.selection.remove(i) } else { model.beats.selection.insert(i) }
                            } else {
                                model.beats.selection = [i]
                            }
                            dragging = i
                            model.beginGesture()
                        } else if NSEvent.modifierFlags.contains(.option) {
                            model.addBeat(at: t)
                            dragging = model.beats.selection.first
                            model.beginGesture()
                        } else {
                            // Empty space: scrub from here.
                            model.beats.selection = []
                            scrubbing = true
                            model.seek(to: t)
                        }
                    } else if let i = dragging, abs(g.translation.width) > 2 {
                        model.beats.move(i, to: t)
                    }
                    focused = true
                }
                .onEnded { _ in
                    if dragging != nil { model.endGesture() }
                    dragging = nil
                    scrubbing = false
                }
        )
        .onContinuousHover { phase in
            switch phase {
            case .active(let p):
                if p.y < 12 || scrubbing { NSCursor.resizeLeftRight.set() }
                else if model.beats.nearest(to: p.x / pps, within: 6 / pps) != nil { NSCursor.openHand.set() }
                else { NSCursor.arrow.set() }
            case .ended: NSCursor.arrow.set()
            }
        }
    }

    func draw(_ ctx: GraphicsContext, size: CGSize, pps: Double) {
        let ruler = 10.0
        let base = size.height - 2
        let amp = size.height - ruler - 6
        ctx.fill(Path(CGRect(x: 0, y: ruler, width: size.width, height: size.height - ruler)),
                 with: .color(Color(nsColor: .textBackgroundColor)))

        // Ruler: a tick every second (the seconds are labelled in the timeline's top ruler).
        var s = 0
        while Double(s) * pps <= size.width {
            let x = Double(s) * pps
            ctx.stroke(Path { $0.move(to: CGPoint(x: x, y: ruler - 5)); $0.addLine(to: CGPoint(x: x, y: ruler)) },
                       with: .color(.secondary), lineWidth: 1)
            s += 1
        }

        // Waveform, one column per pixel.
        if let w = model.waveform {
            var path = Path()
            var x = 0.0
            while x < size.width {
                // Half waveform: the peak level, from the bottom up.
                let (lo, hi) = w.range(from: x / pps, to: (x + 1) / pps)
                let level = Double(max(abs(lo), abs(hi)))
                path.addRect(CGRect(x: x, y: base - level * amp, width: 1, height: max(1, level * amp)))
                x += 1
            }
            ctx.fill(path, with: .color(.secondary.opacity(0.55)))
        }

        // Beats.
        for (i, t) in model.beats.times.enumerated() {
            let x = t * pps
            let selected = model.beats.selection.contains(i)
            ctx.stroke(Path { $0.move(to: CGPoint(x: x, y: ruler)); $0.addLine(to: CGPoint(x: x, y: size.height)) },
                       with: .color(selected ? .orange : .accentColor), lineWidth: selected ? 2.5 : 1.2)
            if pps * (model.beats.times.count > 1 ? (model.duration / Double(model.beats.times.count)) : 1) > 18 {
                ctx.draw(Text("\(i + 1)").font(.system(size: 9, weight: selected ? .bold : .regular))
                            .foregroundStyle(selected ? Color.orange : Color.accentColor),
                         at: CGPoint(x: x + 2, y: ruler + 2), anchor: .topLeading)
            }
        }
    }

    // MARK: Keys and panels

    func handleKey(_ press: KeyPress) -> KeyPress.Result {
        let frame = 1001.0 / 30000
        switch press.key {
        case .space: model.togglePlay(); return .handled
        case .delete, .deleteForward:
            if !model.beats.selection.isEmpty { model.beats.deleteSelected(); return .handled }
            guard let onDeleteWithoutBeats else { return .ignored }
            onDeleteWithoutBeats()
            return .handled
        case .leftArrow: model.beats.nudgeSelected(by: press.modifiers.contains(.shift) ? -frame : -0.005); return .handled
        case .rightArrow: model.beats.nudgeSelected(by: press.modifiers.contains(.shift) ? frame : 0.005); return .handled
        case .escape: model.beats.selection = []; return .handled
        case .home: model.seek(to: 0); return .handled
        case .end: model.seek(to: model.duration); return .handled
        default: break
        }
        if press.characters.lowercased() == "t" && press.modifiers.isEmpty { model.tap(); return .handled }
        if press.characters.lowercased() == "a" && press.modifiers.contains(.command) { model.beats.selectAll(); return .handled }
        return .ignored
    }

    func openPanel() {
        let p = NSOpenPanel()
        p.allowedContentTypes = [.audio, .mp3, .mpeg4Audio, .wav, .aiff]
        p.allowsMultipleSelection = false
        if p.runModal() == .OK, let url = p.url { Task { await model.open(url) } }
    }
}

/// The playhead over the waveform, with a handle in the ruler. Its own view: it alone redraws as the playhead
/// moves, not the waveform under it.
struct PlayheadLine: View {
    let model: BeatEditorModel
    let pps: Double
    var body: some View {
        let px = model.playhead * pps
        Canvas { ctx, size in
            ctx.stroke(Path { $0.move(to: CGPoint(x: px, y: 0)); $0.addLine(to: CGPoint(x: px, y: size.height)) },
                       with: .color(.red), lineWidth: 1.5)
            ctx.fill(Path { p in
                p.move(to: CGPoint(x: px - 6, y: 0)); p.addLine(to: CGPoint(x: px + 6, y: 0)); p.addLine(to: CGPoint(x: px, y: 10))
                p.closeSubpath()
            }, with: .color(.red))
        }
    }
}

/// The playhead's time in seconds (its own view, for the same reason).
struct PlayheadTime: View {
    let model: BeatEditorModel
    var body: some View {
        Text(String(format: "%.2f s", model.playhead)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
    }
}
