import Foundation
import Testing
@testable import SidebarModel

struct CrossWindowDropTests {
    @Test func rowDropUsesDestinationContainerWhileSourceRemainsKey() throws {
        let store = SidebarStore()
        let source = store.activeSpaceID
        let moving = store.addTab(kind: .today, title: "Moving", url: URL(string: "https://moving.test")!)
        let destination = store.addSpace(name: "Destination")
        store.selectSpace(destination.id)
        let first = store.addTab(kind: .today, title: "First", url: URL(string: "https://first.test")!)
        let second = store.addTab(kind: .today, title: "Second", url: URL(string: "https://second.test")!)
        store.selectSpace(source)
        let sourceWindow = SidebarWindowID(), targetWindow = SidebarWindowID()
        store.registerWindow(sourceWindow, spaceID: source)
        store.registerWindow(targetWindow, spaceID: destination.id)
        store.windowBecameKey(sourceWindow)
        #expect(store.moveItem(moving.id, relativeTo: first.id, after: true))
        let ids = store.entries(in: .section(spaceID: destination.id, section: .unpinned)).map(\.id)
        #expect(ids.firstIndex(of: moving.id) == ids.firstIndex(of: first.id).map { $0 + 1 })
        #expect(ids.contains(second.id))
        #expect(store.spaceContaining(tabID: moving.id) == destination.id)
        #expect(store.focusedSpaceID(in: sourceWindow) == source)
        #expect(store.focusedSpaceID(in: targetWindow) == destination.id)
        #expect(store.activeSpaceID == source)
    }

    @Test func emptySectionDropPinsAndRejectsUnknownSourceWithoutSwitchingSpaces() {
        let store = SidebarStore()
        let source = store.activeSpaceID
        let moving = store.addTab(kind: .today, title: "Moving", url: URL(string: "https://moving.test")!)
        let destination = store.addSpace(name: "Destination")
        #expect(store.moveItem(moving.id, to: .section(spaceID: destination.id, section: .pinned), index: 0))
        #expect(store.kind(of: moving.id) == .pinned)
        #expect(store.content(for: destination.id).pinned.map(\.id) == [moving.id])
        #expect(!store.moveItem(UUID(), relativeTo: moving.id, after: false))
        #expect(store.activeSpaceID == source)
    }
}
