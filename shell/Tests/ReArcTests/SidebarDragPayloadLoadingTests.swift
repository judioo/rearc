import AppKit
import Testing
import SidebarModel
@testable import ReArc

@MainActor
struct SidebarDragPayloadLoadingTests {
    @Test func anotherWindowLoadsPrivateDragWithoutLocalBinding() async {
        let id = UUID()
        let loaded = await withCheckedContinuation { continuation in
            #expect(SidebarDragPayload.load([SidebarDragPayload.itemProvider(for: id)]) { continuation.resume(returning: $0) })
        }
        #expect(loaded == id)
        #expect(!SidebarDragPayload.load([NSItemProvider(object: id.uuidString as NSString)]) { _ in Issue.record("Plain text is not an internal drag") })
    }
}
