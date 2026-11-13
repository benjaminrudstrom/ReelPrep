import Testing
import ReelCore
@testable import ReelUI

@MainActor @Suite struct BeatUndoTests {
    @Test func undoRedoAndDragIsOneStep() {
        let m = BeatEditorModel()
        m.beats = BeatList([0.5, 1.0, 1.5], duration: 10)
        m.beats.add(at: 2.0)
        #expect(m.beats.times == [0.5, 1.0, 1.5, 2.0] && m.canUndo)
        // A drag: many moves, one undo step.
        m.beginGesture()
        for x in stride(from: 1.0, through: 1.3, by: 0.05) { m.beats.move(1, to: x) }
        m.endGesture()
        #expect(abs(m.beats.times[1] - 1.3) < 1e-9)
        m.undo()
        #expect(m.beats.times == [0.5, 1.0, 1.5, 2.0])
        m.undo()
        #expect(m.beats.times == [0.5, 1.0, 1.5])
        m.redo()
        #expect(m.beats.times == [0.5, 1.0, 1.5, 2.0] && m.canRedo)
        m.beats.deleteSelected()   // a new edit clears redo
        #expect(!m.canRedo)
    }
}
