import SwiftUI
import SidebarModel

/// Keeps per-keystroke observation inside the overlay, away from BrowserView's
/// sidebar, content, sheets and theme.
struct CommandBarContainer: View {
    @Bindable var model: BrowserViewModel
    let width: CGFloat

    var body: some View {
        CommandBarOverlay(
            text: $model.commandBarText,
            inlineSuffix: model.commandBarInlineSuffix,
            onAcceptCompletion: { model.acceptCommandBarInlineCompletion() },
            onSubmitRoute: { model.submitCommandBar(route: $0) },
            results: model.commandBarResults,
            highlightedIndex: model.commandBarHighlightedIndex,
            errorMessage: model.commandBarError,
            siteSearch: model.commandBarSiteSearch,
            siteSearchSuggestion: model.commandBarSiteSearchSuggestion,
            onTab: { model.enterCommandBarSiteSearch() },
            onDeleteBackward: { model.exitCommandBarSiteSearch() },
            onDeleteHighlighted: { model.deleteHighlightedCommandBarHistoryRow() },
            onRowAction: { model.performCommandBarRowAction($0, on: $1) },
            onMoveHighlight: { model.moveCommandBarHighlight(by: $0) },
            onSelectIndex: { index in
                model.commandBarHighlightedIndex = index
                model.submitCommandBar()
            },
            onSubmit: { model.submitCommandBar() },
            onCancel: { model.dismissCommandBar() },
            focusRequest: model.commandBarFocusRequest,
            width: width,
            spaceName: { model.store.space(withID: $0)?.name }
        )
    }

}
