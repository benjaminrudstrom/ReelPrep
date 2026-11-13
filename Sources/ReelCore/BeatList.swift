import Foundation

/// A song's beats being corrected by hand: sorted times in seconds plus a selection.
/// Pure value logic, used by the beat editor (Step 2) and the app.
public struct BeatList: Equatable, Sendable {
    public private(set) var times: [Double]
    public var selection: Set<Int> = []
    public var duration: Double
    /// Beats closer than this are treated as one.
    public static let minimumGap = 0.05

    public init(_ times: [Double], duration: Double) {
        self.duration = duration
        self.times = BeatList.cleaned(times, duration: duration)
    }

    static func cleaned(_ t: [Double], duration: Double) -> [Double] {
        var out: [Double] = []
        for x in t.sorted() where x >= 0 && x <= duration {
            if let last = out.last, x - last < minimumGap { continue }
            out.append(x)
        }
        return out
    }

    /// Index of the beat nearest `time` within `tolerance` seconds.
    public func nearest(to time: Double, within tolerance: Double) -> Int? {
        guard !times.isEmpty else { return nil }
        let i = insertionIndex(time)
        let candidates = [i - 1, i].filter { times.indices.contains($0) }
        guard let best = candidates.min(by: { abs(times[$0] - time) < abs(times[$1] - time) }) else { return nil }
        return abs(times[best] - time) <= tolerance ? best : nil
    }

    func insertionIndex(_ time: Double) -> Int {
        var lo = 0, hi = times.count
        while lo < hi { let m = (lo + hi) / 2; if times[m] < time { lo = m + 1 } else { hi = m } }
        return lo
    }

    /// Adds a beat (ignored if one is within `minimumGap`); selects it. Returns its index.
    @discardableResult
    public mutating func add(at time: Double) -> Int? {
        let t = min(max(0, time), duration)
        if let n = nearest(to: t, within: BeatList.minimumGap) { selection = [n]; return nil }
        let i = insertionIndex(t)
        times.insert(t, at: i)
        selection = [i]
        return i
    }

    public mutating func deleteSelected() {
        guard !selection.isEmpty else { return }
        let first = selection.min()!
        times = times.enumerated().filter { !selection.contains($0.offset) }.map(\.element)
        selection = times.isEmpty ? [] : [min(first, times.count - 1)]
    }

    /// Moves the selected beats by `delta` seconds, keeping order and the minimum gap to the others.
    public mutating func nudgeSelected(by delta: Double) {
        guard !selection.isEmpty else { return }
        let moved = selection.map { times[$0] + delta }
        guard moved.allSatisfy({ $0 >= 0 && $0 <= duration }) else { return }
        let others = times.enumerated().filter { !selection.contains($0.offset) }.map(\.element)
        for m in moved where others.contains(where: { abs($0 - m) < BeatList.minimumGap }) { return }
        let selectedTimes = Set(moved)
        times = (others + moved).sorted()
        selection = Set(times.indices.filter { selectedTimes.contains(times[$0]) })
    }

    /// Moves one beat to `time` (dragging); stays between its neighbours.
    public mutating func move(_ index: Int, to time: Double) {
        guard times.indices.contains(index) else { return }
        let lo = index > 0 ? times[index - 1] + BeatList.minimumGap : 0
        let hi = index < times.count - 1 ? times[index + 1] - BeatList.minimumGap : duration
        guard lo <= hi else { return }
        times[index] = min(max(time, lo), hi)
        selection = [index]
    }

    public mutating func selectAll() { selection = Set(times.indices) }

    /// Tempo from the median beat interval.
    public var bpm: Double? {
        guard times.count >= 2 else { return nil }
        let gaps = zip(times, times.dropFirst()).map { $1 - $0 }.sorted()
        let m = gaps[gaps.count / 2]
        return m > 0 ? 60 / m : nil
    }
}
