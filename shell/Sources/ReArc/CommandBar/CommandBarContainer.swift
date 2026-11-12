import SwiftUI
import SidebarModel

/// Keeps per-keystroke observation inside the overlay, away from BrowserView's
/// sidebar, content, sheets and theme.
struct CommandBarContainer: View {
    @Bindable var model: BrowserViewModel
    let width: CGFloat

    @Environment(\.themeChrome) private var themeChrome

    var body: some View {
        let siteSearch = model.commandBarSiteSearch
        CommandBarOverlay(
            text: $model.commandBarText,
            inlineSuffix: model.commandBarInlineSuffix,
            onAcceptCompletion: { model.acceptCommandBarInlineCompletion() },
            onSubmitRoute: { model.submitCommandBar(route: $0) },
            results: model.commandBarResults,
            highlightedIndex: model.commandBarHighlightedIndex,
            errorMessage: model.commandBarError,
            siteSearch: siteSearch,
            siteSearchSuggestion: model.commandBarSiteSearchSuggestion,
            siteSearchFill: siteSearch.map {
                model.commandBarSiteFill($0, accentFill: themeChrome.commandBarFill, dark: themeChrome.isWindowDark)
            },
            collapseCount: model.commandBarCollapseCount,
            onTab: { model.enterCommandBarSiteSearch() },
            onDeleteBackward: { model.exitCommandBarSiteSearch() },
            onDeleteHighlighted: { model.deleteHighlightedCommandBarHistoryRow() },
            onRowAction: { model.performCommandBarRowAction($0, on: $1) },
            onMoveHighlight: { model.moveCommandBarHighlight(by: $0) },
            onSelectResult: { id in
                guard let index = model.commandBarResults.firstIndex(where: { $0.id == id }) else { return }
                model.commandBarHighlightedIndex = index
                model.submitCommandBar()
            },
            onSubmit: { model.submitCommandBar() },
            onCancel: { model.dismissCommandBar() },
            focusRequest: model.commandBarFocusRequest,
            width: width,
            spaceName: { id in id == model.store.activeSpaceID ? nil : model.store.space(withID: id)?.name },
            favicon: { model.faviconStore.image(for: $0) }
        )
    }

}
