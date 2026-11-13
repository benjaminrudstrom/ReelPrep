import Testing
@testable import ReelCore

@Suite struct BeatListTests {
    @Test func cleansSortsAndDropsNearDuplicates() {
        let b = BeatList([1.0, 0.5, 0.52, 2.0, 12], duration: 10)
        #expect(b.times == [0.5, 1.0, 2.0])
    }

    @Test func addSelectAndDelete() {
        var b = BeatList([0.5, 1.0, 1.5], duration: 10)
        #expect(b.add(at: 0.75) == 1)
        #expect(b.times == [0.5, 0.75, 1.0, 1.5] && b.selection == [1])
        #expect(b.add(at: 0.76) == nil)        // too close: selects the existing one
        #expect(b.times.count == 4)
        b.deleteSelected()
        #expect(b.times == [0.5, 1.0, 1.5] && b.selection == [1])
    }

    @Test func nudgeKeepsGapsAndBounds() {
        var b = BeatList([0.5, 1.0, 1.5], duration: 2)
        b.selection = [1]
        b.nudgeSelected(by: 0.01)
        #expect(abs(b.times[1] - 1.01) < 1e-9)
        b.nudgeSelected(by: 0.47)               // would land within 50 ms of 1.5: refused
        #expect(abs(b.times[1] - 1.01) < 1e-9)
        b.selectAll()
        b.nudgeSelected(by: -0.02)              // shift everything
        #expect(b.times.map { ($0 * 100).rounded() / 100 } == [0.48, 0.99, 1.48])
        b.nudgeSelected(by: 1)                  // past the end: refused
        #expect(b.times.last! < 1.5)
    }

    @Test func dragStaysBetweenNeighbours() {
        var b = BeatList([0.5, 1.0, 1.5], duration: 10)
        b.move(1, to: 3)
        #expect(abs(b.times[1] - 1.45) < 1e-9)
        #expect(b.nearest(to: 1.47, within: 0.05) == 1)
        #expect(b.nearest(to: 3, within: 0.05) == nil)
    }

    @Test func bpmFromMedianInterval() {
        #expect(abs(BeatList([0, 0.676, 1.351, 2.027, 5], duration: 10).bpm! - 88.8) < 0.3)
    }
}
