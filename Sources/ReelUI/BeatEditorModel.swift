import AVFoundation
import Foundation
import Observation
import ReelCore
import ReelMedia

/// State of the beat editor: one song, its waveform, its beats being corrected, playback.
@MainActor @Observable
public final class BeatEditorModel {
    public private(set) var songURL: URL?
    public private(set) var waveform: Waveform?
    public var beats = BeatList([], duration: 0) {
        didSet { if beats.times != oldValue.times { dirty = true; recordUndo(oldValue) } }
    }
    /// Undo/redo of beat edits (⌘Z / ⇧⌘Z). A drag is one step.
    @ObservationIgnored private var undoStack: [BeatList] = []
    @ObservationIgnored private var redoStack: [BeatList] = []
    @ObservationIgnored private var restoring = false
    @ObservationIgnored private var inGesture = false
    @ObservationIgnored private var gestureRecorded = false
    public internal(set) var canUndo = false
    public internal(set) var canRedo = false
    /// In the app the project keeps one undo history for everything (beats, cuts, framing, logo): beat
    /// changes are recorded there and ⌘Z / ⇧⌘Z go to it.
    @ObservationIgnored weak var undoHost: ReelProject?
    /// Where the beats on screen came from, and what a hand correction started from.
    public private(set) var source: BeatSource = .reelPrep
    public private(set) var basedOn: BeatSource = .reelPrep
    public private(set) var dirty = false
    public private(set) var loading = false
    public private(set) var playing = false
    public var playhead: Double = 0
    /// Horizontal zoom: 1 = the whole song fits the window.
    public var zoom: Double = 1
    /// Snap tapped beats (T) to the nearest attack.
    public var snapTaps = true
    public var message: String?

    private var player: AVAudioPlayer?
    /// While playing: the audio device's clock and the song time at the moment playback started, so the
    /// playhead moves smoothly with the sound (AVAudioPlayer.currentTime advances in uneven steps).
    @ObservationIgnored private var anchor: (device: TimeInterval, time: Double)?
    /// Called whenever the playhead moves (every frame while playing, and on a seek). Views that must
    /// follow it use this instead of observing `playhead`, so they aren't redrawn every frame.
    @ObservationIgnored public var onPlayheadMove: (() -> Void)?

    public init() {}

    private func recordUndo(_ old: BeatList) {
        guard !restoring else { return }
        if let host = undoHost { host.edited(); return }
        if inGesture { if gestureRecorded { return }; gestureRecorded = true }
        undoStack.append(old)
        if undoStack.count > 200 { undoStack.removeFirst() }
        redoStack = []
        canUndo = true
        canRedo = false
    }

    /// Changes between these two calls (a drag) undo as one step.
    public func beginGesture() { inGesture = true; gestureRecorded = false }
    public func endGesture() { inGesture = false }

    /// Puts back beats from the project's undo history (not recorded again).
    func restore(_ b: BeatList) {
        restoring = true
        beats = b
        restoring = false
    }

    public func undo() {
        if let host = undoHost { host.undo(); return }
        guard let previous = undoStack.popLast() else { return }
        restoring = true
        redoStack.append(beats)
        beats = previous
        restoring = false
        canUndo = !undoStack.isEmpty
        canRedo = true
    }

    public func redo() {
        if let host = undoHost { host.redo(); return }
        guard let next = redoStack.popLast() else { return }
        restoring = true
        undoStack.append(beats)
        beats = next
        restoring = false
        canUndo = true
        canRedo = !redoStack.isEmpty
    }

    private func clearUndo() {
        undoStack = []
        redoStack = []
        canUndo = false
        canRedo = false
    }

    public var duration: Double { waveform?.duration ?? beats.duration }

    public func open(_ url: URL) async {
        loading = true
        message = nil
        defer { loading = false }
        do {
            let (wave, found) = try await Task.detached(priority: .userInitiated) {
                (try Waveform.load(url), try BeatStore.beats(for: url))
            }.value
            stop()
            songURL = url
            waveform = wave
            restoring = true
            beats = BeatList(found.beats, duration: wave.duration)
            restoring = false
            clearUndo()
            source = found.source
            basedOn = found.source == .corrected ? (BeatStore.load(for: url)?.basedOn ?? .reelPrep) : found.source
            dirty = false
            playhead = 0
            player = try AVAudioPlayer(contentsOf: url)
            player?.prepareToPlay()
        } catch {
            message = "Couldn't open \(url.lastPathComponent): \(error.localizedDescription)"
        }
    }

    /// Forgets the song (a new, empty reel).
    public func close() {
        stop()
        player = nil
        songURL = nil
        waveform = nil
        restoring = true
        beats = BeatList([], duration: 0)
        restoring = false
        clearUndo()
        dirty = false
        playhead = 0
        message = nil
    }

    // MARK: Playback

    public func togglePlay() {
        guard let p = player else { return }
        if playing {
            playhead = now
            p.pause()
            playing = false
            anchor = nil
        } else {
            if playhead >= duration - 0.05 { playhead = 0 }
            p.currentTime = playhead
            let start = p.deviceCurrentTime + 0.02
            p.play(atTime: start)
            anchor = (start, playhead)
            playing = true
        }
    }

    public func stop() {
        player?.stop()
        playing = false
        anchor = nil
    }

    /// The song time now: from the audio device's clock while playing.
    private var now: Double {
        guard playing, let p = player, let a = anchor else { return playhead }
        return min(duration, a.time + max(0, p.deviceCurrentTime - a.device))
    }

    /// Called every frame while playing.
    public func tick() {
        guard playing, let p = player, let a = anchor else { return }
        let t = now
        if t >= duration || (!p.isPlaying && p.deviceCurrentTime > a.device + 0.2) {
            stop()
            playhead = duration
        } else {
            playhead = t
        }
        onPlayheadMove?()
    }

    public func seek(to time: Double) {
        playhead = min(max(0, time), duration)
        if let p = player {
            p.currentTime = playhead
            if playing { anchor = (p.deviceCurrentTime, playhead) }
        }
        onPlayheadMove?()
    }

    // MARK: Editing

    /// T: a beat at the playhead (while listening), snapped to the nearest attack.
    public func tap() {
        guard songURL != nil else { return }
        let t = now
        let snapped = snapTaps ? (waveform?.snapToAttack(t) ?? t) : t
        beats.add(at: snapped)
    }

    public func addBeat(at time: Double) { beats.add(at: time) }

    public func save() {
        guard let url = songURL else { return }
        do {
            try BeatStore.save(beats.times, for: url, basedOn: basedOn)
            source = .corrected
            dirty = false
            message = "Saved \(beats.times.count) beats. reelprep uses them for this song from now on."
        } catch {
            message = "Couldn't save: \(error.localizedDescription)"
        }
    }

    /// Back to the detected beats (Final Cut's or ReelPrep's), forgetting the saved correction.
    public func revert() async {
        guard let url = songURL else { return }
        do {
            let found = try await Task.detached { try BeatStore.detected(for: url) }.value
            try BeatStore.remove(for: url)
            beats = BeatList(found.beats, duration: duration)
            source = found.source
            basedOn = found.source
            dirty = false
            message = "Back to \(found.source.rawValue)."
        } catch {
            message = "Couldn't revert: \(error.localizedDescription)"
        }
    }

    public var title: String {
        guard let u = songURL else { return "Beats" }
        return u.deletingPathExtension().lastPathComponent + (dirty ? " — edited" : "")
    }
}
