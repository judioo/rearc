import Foundation
import Testing
import SidebarModel
@testable import ReArc

@MainActor
struct LittleArcSplitShellTests {
    private final class Presenter: BrowserWindowPresenting {
        var focused: [SidebarWindowID] = []
        var dismissed: [LittleArcWindow.ID] = []
        func presentLittleArcWindow(_ id: LittleArcWindow.ID) {}
        func dismissLittleArcWindow(_ id: LittleArcWindow.ID) { dismissed.append(id) }
        func presentPrivateWindow(_ window: PrivateWindowModel) {}
        func focusBrowserWindow(_ id: SidebarWindowID) { focused.append(id) }
    }

    @Test func usesTheLiveURLAndLastBrowserWindow() throws {
        let store = SidebarStore(spaces: [Space(name: "One")])
        let two = store.addSpace(name: "Two")
        let first = SidebarWindowID(), second = SidebarWindowID()
        store.registerWindow(first)
        store.registerWindow(second, spaceID: two.id)
        store.windowBecameKey(second)
        let anchor = store.addTab(kind: .today, title: "Anchor", url: URL(string: "https://anchor.test")!)
        let model = BrowserViewModel(store: store, persistence: SidebarFilePersistence(fileURL: FileManager.default.temporaryDirectory.appendingPathComponent("little-split-\(UUID().uuidString).json")))
        let presenter = Presenter()
        model.windowPresenter = presenter
        let little = store.createLittleArcWindow(url: URL(string: "https://original.test")!)
        let engine = model.littleArcEngine(for: little.id)
        let live = URL(string: "about:blank#live")!
        engine.load(live)
        model.keyLittleArcID = little.id
        #expect(model.canSplitLittleArcWindow(little.id))
        #expect(model.splitLittleArcWindow(little.id))
        let split = try #require(model.activeSplit(in: second))
        #expect(split.tabs.map(\.url) == [anchor.url, live])
        #expect(store.focusedSpaceID(in: first) != two.id)
        #expect(presenter.focused == [second])
        #expect(presenter.dismissed == [little.id])
        #expect(model.keyLittleArcID == nil)
        #expect(model.engineHost.existingLittleArcEngine(little.id, profileID: little.profileID) == nil)
    }
}
