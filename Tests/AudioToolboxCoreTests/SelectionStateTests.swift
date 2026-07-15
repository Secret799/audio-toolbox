import Testing
@testable import AudioToolboxCore

@Suite("SelectionStateTests")
struct SelectionStateTests {
    @Test
    func selectionSurvivesGroupChangesAndToggleAllOnlyAffectsCurrentGroup() {
        let firstGroup = [identity("a"), identity("b")]
        let secondGroup = [identity("c"), identity("d")]
        var selection = SelectionState()

        selection.toggle(firstGroup[0])
        selection.setSelected(secondGroup, selected: true)
        selection.setSelected([secondGroup[0]], selected: false)
        selection.setSelected(firstGroup, selected: true)
        selection.setSelected(firstGroup, selected: false)

        #expect(selection.ids == Set([identity("d")]))
    }

    @Test
    func toggleAddsAndRemovesTheSameIdentity() {
        var selection = SelectionState()

        selection.toggle(identity("a"))
        #expect(selection.ids == Set([identity("a")]))

        selection.toggle(identity("a"))
        #expect(selection.ids.isEmpty)
    }

    @Test
    func retainOnlyAndRemoveAllPruneSelection() {
        var selection = SelectionState()
        selection.setSelected([identity("a"), identity("b"), identity("c")], selected: true)

        selection.retainOnly(Set([identity("b"), identity("c"), identity("d")]))
        #expect(selection.ids == Set([identity("b"), identity("c")]))

        selection.removeAll()
        #expect(selection.ids.isEmpty)
    }

    private func identity(_ rawValue: String) -> FileIdentity {
        FileIdentity(rawValue: rawValue)
    }
}
