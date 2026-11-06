import Testing
@testable import SidebarModel

struct MenuCommandSearchTests {
    let zoom = MenuCommand(id: "zoom", title: "Actual Size", path: "View › Zoom › Actual Size", keyEquivalent: "⌘0")

    @Test func matchesTitleAndMenuPath() {
        #expect(MenuCommandSearch.matches([zoom], query: "actual", registered: []) == [zoom])
        #expect(MenuCommandSearch.matches([zoom], query: "view zoom", registered: []) == [zoom])
        #expect(MenuCommandSearch.matches([zoom], query: "unrelated", registered: []).isEmpty)
    }

    @Test func filtersDisabledActionlessAndDuplicateRegisteredTitles() {
        var disabled = zoom, actionless = zoom
        disabled.isEnabled = false
        actionless.hasAction = false
        #expect(MenuCommandSearch.matches([disabled, actionless], query: "", registered: []).isEmpty)
        let registered = AppCommand(id: "size", title: "Actual Size…", keywords: [], action: .reloadPage)
        #expect(MenuCommandSearch.matches([zoom, zoom], query: "", registered: [registered]).isEmpty)
        #expect(MenuCommandSearch.matches([zoom, zoom], query: "", registered: []) == [zoom])
    }

    @Test func quitAndHideRequireExactTitle() {
        let quit = MenuCommand(id: "quit", title: "Quit ReArc", path: "ReArc › Quit ReArc", requiresExactQuery: true)
        for query in ["", "quit", "qra", "rearc"] {
            #expect(MenuCommandSearch.matches([quit], query: query, registered: []).isEmpty)
        }
        #expect(MenuCommandSearch.matches([quit], query: " QUIT REARC ", registered: []) == [quit])
    }

    @Test func menuRowsFollowRegisteredCommandsAndCarryShortcut() {
        let registered = AppCommand(id: "zoom", title: "Zoom In", keywords: [], action: .reloadPage)
        let rows = CommandBarSearch.results(for: ">", in: SidebarStore(), commandCatalog: [registered], menuCommands: [zoom])
        #expect(rows.map(\.title) == ["Zoom In", "Actual Size"])
        #expect(rows.last?.menuCommandID == "zoom")
        #expect(rows.last?.subtitle == zoom.path)
        #expect(rows.last?.keyEquivalent == "⌘0")
    }
}
