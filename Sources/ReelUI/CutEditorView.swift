import AppKit
import AVFoundation
import SwiftUI
import FCPXMLKit
import ReelCore
import ReelMedia

/// A cut's zoom effect in its proxy's time: scale `from` at `start` (seconds) to `to` after `duration`.
struct PushAnimation: Equatable, Sendable {
    var start: Double, duration: Double, from: Double, to: Double

    /// A video composition that zooms each frame at that frame's own time, as the export does. Baked into
    /// the frames, the zoom can't drift from the picture: a scale set on the layer (from the main thread
    /// or by Core Animation on the item's clock) ran smoothly while the video moves in frame steps, and
    /// ran ahead of the picture while scrubbing, which wobbled.
    func composition(for asset: AVAsset) async -> AVVideoComposition? {
        let p = self
        return try? await AVMutableVideoComposition.videoComposition(with: asset) { request in
            let t = (request.compositionTime.seconds - p.start) / p.duration
            let s = p.from + (p.to - p.from) * min(max(t, 0), 1)
            let image = request.sourceImage, e = image.extent
            let zoom = CGAffineTransform(translationX: -e.midX, y: -e.midY)
                .concatenating(CGAffineTransform(scaleX: s, y: s))
                .concatenating(CGAffineTransform(translationX: e.midX, y: e.midY))
            request.finish(with: image.transformed(by: zoom).cropped(to: e), context: nil)
        }
    }
}

/// An AVPlayerLayer in SwiftUI (fills its frame).
struct PlayerLayerView: NSViewRepresentable {
    let player: AVPlayer
    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        v.wantsLayer = true
        let l = AVPlayerLayer(player: player)
        l.videoGravity = .resizeAspectFill
        v.layer = l
        return v
    }
    func updateNSView(_ v: NSView, context: Context) { (v.layer as? AVPlayerLayer)?.player = player }
}

/// Playback in the preview. One cut: loops its window at the reel's speed (50 % for 60 fps).
/// The whole reel (space): two players take turns. While one plays the current cut, the other loads the
/// next cut and waits on its first frame, so the preview switches at the cut without a hiccup.
@MainActor @Observable
final class CutPlayer {
    let players = [AVPlayer(), AVPlayer()]
    /// The player on screen.
    private(set) var active = 0
    var player: AVPlayer { players[active] }
    private var urls: [URL?] = [nil, nil]
    var url: URL? { urls[active] }
    private(set) var playing = false
    private var window: (start: Double, end: Double, rate: Float) = (0, 0, 1)
    private var observer: Any?
    /// Following the reel's playhead (spacebar playback) instead of looping one cut.
    private(set) var reelMode = false
    private var reelSlot: Int?
    /// The other player, loaded and waiting at the start of this cut.
    private var prepared: Int?

    /// The zoom effect of the cut a proxy is shown for (set by the editor).
    @ObservationIgnored var zoomEffect: ((URL) -> PushAnimation?)?
    @ObservationIgnored private var zoomOn: [ObjectIdentifier: PushAnimation] = [:]

    init() { players.forEach { $0.isMuted = true } }

    private func load(_ proxy: URL, into i: Int) {
        guard urls[i] != proxy else { return }
        urls[i] = proxy
        players[i].replaceCurrentItem(with: AVPlayerItem(url: proxy))
        applyZoom(i)
    }

    /// Puts each player's cut's zoom effect (as it is now) on its item.
    func refreshZoom() { for i in players.indices { applyZoom(i) } }

    private func applyZoom(_ i: Int) {
        guard let url = urls[i], let item = players[i].currentItem else { return }
        let id = ObjectIdentifier(item), push = zoomEffect?(url)
        guard push != zoomOn[id] else { return }
        zoomOn[id] = push
        guard let push else { item.videoComposition = nil; return }
        Task {
            let vc = await push.composition(for: item.asset)
            guard zoomOn[id] == push else { return }
            item.videoComposition = vc
            // Stopped: show the frame again with the new zoom.
            let p = players[i]
            if p.rate == 0, p.currentItem === item {
                if reelMode && i != active && prepared != nil { prime(i, at: p.currentTime().seconds, rate: primeRate[i]) }
                else { seek(p, p.currentTime().seconds) }
            }
        }
    }

    private func seek(_ p: AVPlayer, _ t: Double) {
        p.seek(to: CMTime(seconds: t, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
    }

    /// Shows the reel at the playhead: cut `slot` from `proxy` at `time` (proxy seconds), playing at `rate`
    /// or paused. Seeks only when the cut changes (or while paused). `next` is the following cut, made ready
    /// on the other player.
    func followReel(proxy: URL, slot: Int, time: Double, rate: Float, playing: Bool,
                    next: (proxy: URL, slot: Int, time: Double, rate: Float)? = nil) {
        reelMode = true
        if slot != reelSlot {
            let previous = active
            if prepared == slot, urls[1 - active] == proxy {
                active = 1 - active          // the next cut is ready on the other player: just switch
            } else {
                load(proxy, into: active)
                seek(player, time)
            }
            if previous != active { players[previous].pause() }
            reelSlot = slot
            prepared = nil
        } else if !playing {
            seek(player, time)
        }
        if playing {
            if player.rate != rate { player.rate = rate }
            // Get the next cut ready on the other player.
            if let next, prepared != next.slot {
                let other = 1 - active
                load(next.proxy, into: other)
                players[other].pause()
                prepared = next.slot
                prime(other, at: next.time, rate: next.rate)
            }
        } else if player.rate != 0 {
            player.pause()
        }
    }

    /// Seeks a waiting player to `time` and prerolls it at `rate`, so it starts at once when its cut comes:
    /// with a zoom effect the frames go through a video composition, which otherwise needs a moment to start.
    private func prime(_ i: Int, at time: Double, rate: Float) {
        let p = players[i], slot = prepared
        primeRate[i] = rate
        p.seek(to: CMTime(seconds: time, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero) { done in
            guard done else { return }
            DispatchQueue.main.async { MainActor.assumeIsolated {
                guard self.prepared == slot, i != self.active, p.rate == 0, p.status == .readyToPlay,
                      p.currentItem?.status == .readyToPlay else { return }
                p.preroll(atRate: rate)
            } }
        }
    }
    @ObservationIgnored private var primeRate: [Float] = [1, 1]

    func endReel() {
        reelMode = false
        reelSlot = nil
        prepared = nil
        players.forEach { $0.pause() }
    }

    /// One cut's clip, on the player on screen.
    func load(_ proxy: URL) {
        guard proxy != url else { return }
        stop()
        load(proxy, into: active)
        if observer == nil {
            for (i, p) in players.enumerated() {
                observer = p.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 30), queue: .main) { [weak self] t in
                    MainActor.assumeIsolated { if self?.active == i { self?.loopIfNeeded(t.seconds) } }
                }
            }
        }
    }

    func setWindow(start: Double, end: Double, rate: Float) {
        window = (start, end, rate)
        if !playing { seek(start) }
    }

    func seek(_ t: Double) { seek(player, t) }

    func toggle() {
        if playing { stop() } else {
            seek(window.start)
            player.rate = window.rate
            playing = true
        }
    }

    func stop() { player.pause(); playing = false }

    private func loopIfNeeded(_ t: Double) {
        if !reelMode && playing && t >= window.end { seek(window.start); player.rate = window.rate }
    }
}

/// Still frames from the proxies, for the clip list and the cut strip (made on demand, kept).
@MainActor @Observable
final class ThumbnailStore {
    private(set) var images: [String: CGImage] = [:]
    @ObservationIgnored private var pending: Set<String> = []  // changed while views draw: must not be observed

    func image(_ proxy: URL?, at seconds: Double) -> CGImage? {
        guard let proxy else { return nil }
        let key = "\(proxy.path)#\(Int((seconds * 10).rounded()))"
        if let img = images[key] { return img }
        if !pending.contains(key) {
            pending.insert(key)
            Task {
                let gen = AVAssetImageGenerator(asset: AVURLAsset(url: proxy))
                gen.appliesPreferredTrackTransform = true
                gen.maximumSize = CGSize(width: 320, height: 320)
                gen.requestedTimeToleranceBefore = CMTime(value: 1, timescale: 10)
                gen.requestedTimeToleranceAfter = CMTime(value: 1, timescale: 10)
                if let (img, _) = try? await gen.image(at: CMTime(seconds: seconds, preferredTimescale: 600)) {
                    images[key] = img
                }
            }
        }
        return nil
    }
}

/// A still that fills whatever frame it's given (cropped to it), or a dark placeholder while it loads.
/// The colour takes the frame's size and the image sits in an overlay, so the image's own size
/// never widens the layout.
struct Thumb: View {
    let image: CGImage?
    var body: some View {
        Color.black.opacity(0.5)
            .overlay {
                if let image { Image(decorative: image, scale: 1).resizable().aspectRatio(contentMode: .fill) }
            }
            .clipped()
    }
}

/// What a cut needs: its clip, its slot and where its window is.
struct CutContext {
    let clip: ClipInfo
    let slot: Slot?
    let plan: ReelPlan
    var neededSeconds: Double {
        guard let s = slot else { return 0 }
        return (plan.frameDuration * (s.endFrame - s.startFrame) * s.speed).seconds
    }
    var inOffset: Double { slot.map { ($0.sourceIn - clip.start).seconds } ?? 0 }
    var rate: Float { slot.map { Float($0.speed.seconds) } ?? 1 }
    /// Whether the logo is on screen at reel frame `f` (the intro logo before its end, the outro from its start).
    func logoShown(at f: Int64) -> Bool {
        (plan.introEndFrame.map { f < $0 } ?? false) || (plan.outroStartFrame.map { f >= $0 } ?? false)
    }
    /// The logo comes or goes during this cut (its edge is on a beat inside it).
    var logoChangesInside: Bool {
        guard let s = slot else { return false }
        return [plan.introEndFrame, plan.outroStartFrame].contains { e in e.map { s.startFrame < $0 && $0 < s.endFrame } ?? false }
    }
    /// The reel frame a player at `seconds` (proxy time) shows.
    func reelFrame(atPlayerSeconds seconds: Double) -> Int64 {
        guard let s = slot else { return 0 }
        let f = s.startFrame + Int64(((seconds - inOffset) / s.speed.seconds / plan.frameDuration.seconds).rounded(.down))
        return min(max(f, s.startFrame), s.endFrame - 1)
    }
}

/// The 9:16 preview, as tall as the window: drag to pan, pinch to zoom, rotate with two fingers to straighten a
/// clip that is a degree or two off (the sliders are in `FramingControls`, under the clip's filmstrip). Logo where it shows.
struct CutPreviewView: View {
    @Bindable var project: ReelProject
    let cut: CutContext
    let cutPlayer: CutPlayer
    @State private var dragStart: Reframe?

    var body: some View {
        let clip = cut.clip
        let r = project.reframe(for: clip)
        return GeometryReader { geo in
            // As tall as the pane allows, and never wider than it.
            let w = max(120, min(geo.size.width - 8, (geo.size.height - 8) * 9 / 16)), h = w * 16 / 9, k = h / 1920
            let (rw, rh) = r.renderedSize(w: Double(clip.width), h: Double(clip.height))
            VStack(spacing: 8) {
                ZStack {
                    Color.black
                    // Both players, the one on screen on top (they take turns at each cut while playing).
                    // The zoom effect is in the frames (CutPlayer.refreshZoom), as in the export.
                    ZStack {
                        ForEach(0..<2, id: \.self) { i in
                            PlayerLayerView(player: cutPlayer.players[i])
                                .frame(width: rw * k, height: rh * k)
                                .rotationEffect(.degrees(-r.angle))
                                .offset(x: r.dx * k, y: r.dy * k)
                                .opacity(cutPlayer.active == i ? 1 : 0)
                        }
                    }
                    .onChange(of: [r.push, cut.inOffset, cut.neededSeconds]) { cutPlayer.refreshZoom() }
                    // The logo while it's on screen: by the frame shown when its edge is inside this cut.
                    if let s = cut.slot, let logoURL = project.logo?.url, let img = NSImage(contentsOf: logoURL) {
                        let inside = cut.logoChangesInside
                        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !inside)) { _ in
                            let f = inside ? cut.reelFrame(atPlayerSeconds: cutPlayer.player.currentTime().seconds) : s.startFrame
                            if cut.logoShown(at: f) {
                                Image(nsImage: img).resizable().scaledToFit().frame(width: w * project.settings.logoWidth)
                            }
                        }
                        .allowsHitTesting(false)
                    }
                    // A level grid while tilting: lines to line verticals and horizons up against.
                    if project.levelGrid {
                        Canvas { ctx, size in
                            for i in 1..<6 {
                                let x = size.width * Double(i) / 6
                                ctx.stroke(Path { $0.move(to: CGPoint(x: x, y: 0)); $0.addLine(to: CGPoint(x: x, y: size.height)) },
                                           with: .color(.white.opacity(0.45)), lineWidth: 0.5)
                            }
                            for i in 1..<10 {
                                let y = size.height * Double(i) / 10
                                ctx.stroke(Path { $0.move(to: CGPoint(x: 0, y: y)); $0.addLine(to: CGPoint(x: size.width, y: y)) },
                                           with: .color(.white.opacity(0.45)), lineWidth: 0.5)
                            }
                        }
                        .allowsHitTesting(false)
                    }
                }
                .frame(width: w, height: h)
                .clipped()
                .contentShape(Rectangle())
                .gesture(DragGesture()
                    .onChanged { g in
                        if dragStart == nil { dragStart = r }
                        let base = dragStart!
                        project.reframes[clip.url] = Reframe(zoom: base.zoom, dx: base.dx + g.translation.width / k,
                                                             dy: base.dy + g.translation.height / k, angle: base.angle, push: base.push)
                            .clamped(w: Double(clip.width), h: Double(clip.height))
                    }
                    .onEnded { _ in dragStart = nil })
                .simultaneousGesture(MagnifyGesture()
                    .onChanged { g in
                        if dragStart == nil { dragStart = r }
                        let base = dragStart!
                        project.reframes[clip.url] = Reframe(zoom: base.zoom * g.magnification, dx: base.dx, dy: base.dy, angle: base.angle, push: base.push)
                            .clamped(w: Double(clip.width), h: Double(clip.height))
                    }
                    .onEnded { _ in dragStart = nil })
                .simultaneousGesture(RotateGesture()
                    .onChanged { g in
                        if dragStart == nil { dragStart = r }
                        project.levelGrid = true
                        let base = dragStart!
                        // Half speed and 0.1° steps: the fixes are small.
                        let a = ((base.angle - g.rotation.degrees / 2) * 10).rounded() / 10
                        project.reframes[clip.url] = Reframe(zoom: base.zoom, dx: base.dx, dy: base.dy, angle: a, push: base.push)
                            .clamped(w: Double(clip.width), h: Double(clip.height))
                    }
                    .onEnded { _ in dragStart = nil; project.levelGrid = false })
                .help("Drag to move the framing, pinch to zoom, rotate with two fingers to straighten")
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding(12)
    }
}

/// The selected cut's details: info, the clip's filmstrip with the window to slide, play.
struct CutDetailView: View {
    @Bindable var project: ReelProject
    let cut: CutContext
    let cutPlayer: CutPlayer
    @State private var thumbs: [CGImage] = []
    @State private var grab: Double?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            filmstrip
            controls
            if cut.slot != nil {
                Divider().padding(.vertical, 4)
                FramingControls(project: project, clip: cut.clip)
            }
        }
        .padding(14)
        .task(id: cut.clip.url) {
            thumbs = []
            if let p = project.proxies[cut.clip.url] { thumbs = await Filmstrip.images(of: p, count: 16, height: 80) }
        }
    }

    var header: some View {
        let clip = cut.clip
        return VStack(alignment: .leading, spacing: 3) {
            Text(clip.name).font(.title3.weight(.semibold))
            Text(details(clip)).font(.callout).foregroundStyle(.secondary)
            if let s = cut.slot {
                Text(String(format: "Cut %d of %d · %.2f–%.2f s on the reel · %d beat%@ · uses %.2f s of the clip%@",
                            (cut.plan.slots.firstIndex(of: s) ?? 0) + 1, cut.plan.slots.count,
                            (cut.plan.frameDuration * s.startFrame).seconds, (cut.plan.frameDuration * s.endFrame).seconds,
                            s.beats, s.beats == 1 ? "" : "s", cut.neededSeconds, s.speed == RationalTime(1) ? "" : " at 50 %"))
                    .font(.callout)
            } else {
                Text("Not in the reel: the song runs out before this clip, or it's too short. Move it up the list, or allow shorter cuts.")
                    .font(.callout).foregroundStyle(.orange)
            }
        }
    }

    func details(_ clip: ClipInfo) -> String {
        var d = "\(clip.width)×\(clip.height) · " + String(format: "%.2f fps · %.2f s", clip.fps, clip.duration.seconds)
        d += " · " + clip.device.rawValue + (clip.deviceModel.map { " (\($0))" } ?? "")
        if let date = clip.captureDate { d += " · " + date.formatted(date: .abbreviated, time: .shortened) }
        return d
    }

    /// Grab the yellow window and slide it, or click elsewhere on the strip to move it there.
    var filmstrip: some View {
        GeometryReader { geo in
            let W = geo.size.width, H = geo.size.height
            let dur = max(cut.clip.duration.seconds, 0.01)
            let need = cut.neededSeconds
            let ww = max(W * need / dur, 6), wx = W * cut.inOffset / dur
            ZStack(alignment: .topLeading) {
                HStack(spacing: 0) {
                    ForEach(Array(thumbs.enumerated()), id: \.offset) { _, img in
                        Thumb(image: img).frame(width: W / CGFloat(max(thumbs.count, 1)), height: H)
                    }
                }
                .frame(width: W, height: H, alignment: .leading)
                .background(Color.black.opacity(0.6))
                if cut.slot != nil {
                    Rectangle().fill(.black.opacity(0.55)).frame(width: max(0, wx), height: H)
                    Rectangle().fill(.black.opacity(0.55)).frame(width: max(0, W - wx - ww), height: H).offset(x: wx + ww)
                    RoundedRectangle(cornerRadius: 3).strokeBorder(Color.yellow, lineWidth: 3)
                        .frame(width: ww, height: H).offset(x: wx)
                } else {
                    Color.black.opacity(0.5)
                }
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { g in
                    guard cut.slot != nil else { return }
                    let maxStart = max(0, dur - need)
                    if grab == nil {
                        let x = g.startLocation.x
                        // Inside the window: slide it. Elsewhere: centre it on the click.
                        grab = (x >= wx - 4 && x <= wx + ww + 4) ? cut.inOffset : x / W * dur - need / 2
                    }
                    let t = min(max(0, grab! + g.translation.width / W * dur), maxStart)
                    project.inPoints[cut.clip.url] = t
                    cutPlayer.stop()
                    cutPlayer.seek(t)
                }
                .onEnded { _ in grab = nil })
            .help("Drag the yellow window to choose the part of the clip used; its length is fixed by the cut")
        }
        .frame(height: 80)
    }

    var controls: some View {
        HStack(spacing: 10) {
            Button(cutPlayer.playing ? "Pause" : "Play cut") { cutPlayer.toggle() }
                .disabled(cut.slot == nil || project.proxies[cut.clip.url] == nil)
                .keyboardShortcut("p", modifiers: [])
            Text(String(format: "from %.2f s", cut.inOffset)).font(.callout.monospacedDigit()).foregroundStyle(.secondary)
            Button("Centre in clip") { project.inPoints[cut.clip.url] = nil }
                .disabled(project.inPoints[cut.clip.url] == nil)
            Spacer()
        }
    }
}

/// How the selected cut sits in the 9:16 frame: zoom and tilt, under the clip in the centre pane. The tilt
/// straightens a clip shot a degree or two off; the crop follows, so no corner ever shows.
struct FramingControls: View {
    @Bindable var project: ReelProject
    let clip: ClipInfo
    /// A new zoom effect's amount (each cut keeps its own; switching in/out keeps it).
    static let defaultPush = 3.0

    var body: some View {
        let r = project.reframe(for: clip)
        Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 8) {
            GridRow {
                Text("Zoom").foregroundStyle(.secondary)
                Image(systemName: "minus.magnifyingglass").foregroundStyle(.secondary)
                Slider(value: Binding(get: { r.zoom }, set: { z in set(Reframe(zoom: z, dx: r.dx, dy: r.dy, angle: r.angle, push: r.push)) }),
                       in: 1...Reframe.maxZoom)
                Image(systemName: "plus.magnifyingglass").foregroundStyle(.secondary)
                Text(String(format: "%.0f %%", r.zoom * 100)).font(.callout.monospacedDigit()).frame(width: 48, alignment: .trailing)
                Button("Centre") { set(Reframe(angle: r.angle, push: r.push)) }
                    .disabled(r.zoom == 1 && r.dx == 0 && r.dy == 0)
                    .help("Back to the middle at zoom 100 % (the tilt stays). Drag the preview to move the framing.")
            }
            GridRow {
                Text("Tilt").foregroundStyle(.secondary)
                Button { tilt(r, to: r.angle - 0.1) } label: { Image(systemName: "chevron.left") }
                    .buttonStyle(.borderless).help("0.1° clockwise")
                Slider(value: Binding(get: { r.angle }, set: { a in tilt(r, to: a) }),
                       in: -Reframe.maxAngle...Reframe.maxAngle) { editing in project.levelGrid = editing }
                Button { tilt(r, to: r.angle + 0.1) } label: { Image(systemName: "chevron.right") }
                    .buttonStyle(.borderless).help("0.1° counter-clockwise")
                Text(String(format: "%+.1f°", r.angle)).font(.callout.monospacedDigit()).frame(width: 48, alignment: .trailing)
                Button("Level") { tilt(r, to: 0) }
                    .disabled(r.angle == 0)
                    .help("No tilt")
            }
            .onHover { inside in project.levelGrid = inside }
            .help("Straighten a clip that is a degree or two off; it is cropped just enough to fill the frame. Or rotate with two fingers on the preview.")
            GridRow {
                Text("Effect").foregroundStyle(.secondary)
                Picker("", selection: Binding(get: { r.push == 0 ? 0 : (r.push > 0 ? 1 : -1) }, set: { d in
                    set(Reframe(zoom: r.zoom, dx: r.dx, dy: r.dy, angle: r.angle, push: Double(d) * (r.push == 0 ? Self.defaultPush : abs(r.push))))
                })) {
                    Text("None").tag(0)
                    Text("Zoom in").tag(1)
                    Text("Zoom out").tag(-1)
                }
                .pickerStyle(.segmented).labelsHidden()
                .gridCellColumns(3)
                // This cut's amount: type it (decimals too, 0.5–10 %) or step it by 1. 3 % until changed.
                let amount = Binding<Double>(get: { r.push == 0 ? Self.defaultPush : abs(r.push) }, set: { v in
                    let a = (min(max(v, 0.5), Reframe.maxPush) * 10).rounded() / 10
                    if r.push != 0 { set(Reframe(zoom: r.zoom, dx: r.dx, dy: r.dy, angle: r.angle, push: (r.push > 0 ? 1 : -1) * a)) }
                })
                HStack(spacing: 3) {
                    TextField("", value: amount, format: .number.precision(.fractionLength(0...1)))
                        .textFieldStyle(.roundedBorder).multilineTextAlignment(.trailing).frame(width: 44)
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(r.push == 0 ? .secondary : .primary)
                    Text("%").foregroundStyle(.secondary)
                    Stepper("", value: amount, in: 0.5...Reframe.maxPush, step: 1).labelsHidden()
                }
                .disabled(r.push == 0)
                .gridCellColumns(2)
            }
            .help("A slow zoom over the whole cut: in from this framing, or out to it. Play the cut to see it.")
        }
        .frame(maxWidth: 560)
    }

    func tilt(_ r: Reframe, to angle: Double) {
        set(Reframe(zoom: r.zoom, dx: r.dx, dy: r.dy, angle: (angle * 10).rounded() / 10, push: r.push))
    }

    func set(_ r: Reframe) {
        let t = r.clamped(w: Double(clip.width), h: Double(clip.height))
        project.reframes[clip.url] = t == .centred ? nil : t
    }
}
