import Testing
import SidebarModel
@testable import ReArc

@MainActor
struct ItemIconPopoverTests {
    @Test func emojiSearchFindsNamesAndGraphemes() {
        #expect(ItemIconEditorView.emojiChoices(matching: "  SMILE ") == ["😀"])
        #expect(ItemIconEditorView.emojiChoices(matching: "❤️") == ["❤️"])
        #expect(ItemIconEditorView.emojiChoices(matching: "absent").isEmpty)
        #expect(ItemIconEditorView.emojiChoices(matching: "").count == 40)
    }

    @Test func acceptsCustomEmojiAndSymbolsWithoutSplittingGraphemes() {
        #expect(ItemIconEditorView.emojiChoices(matching: "👩🏽‍💻") == ["👩🏽‍💻"])
        #expect(ItemIconEditorView.symbolChoices(matching: "arrow.uturn.backward.circle.fill").contains("arrow.uturn.backward.circle.fill"))
        #expect(ItemIconEditorView.symbolChoices(matching: "not-a-symbol").isEmpty)
    }
}
