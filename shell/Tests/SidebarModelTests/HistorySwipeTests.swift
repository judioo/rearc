import Testing
@testable import SidebarModel

struct HistorySwipeTests {
    let edges = HistorySwipe.Edges(back: true, forward: true)

    @Test func commitsBackAndForwardAtThreshold() {
        for x in [50.0, -50.0] {
            var swipe = HistorySwipe()
            let first = swipe.handle(phase: .began, x: x, y: 1, edges: edges, canGoBack: true, canGoForward: true)
            #expect(first.consumes)
            #expect(first.progress == 0.5)
            #expect(first.direction == (x > 0 ? .back : .forward))
            _ = swipe.handle(phase: .changed, x: x, y: 0, edges: edges, canGoBack: true, canGoForward: true)
            #expect(swipe.handle(phase: .ended, x: 0, y: 0, edges: edges, canGoBack: true, canGoForward: true).commit == first.direction)
            #expect(swipe.handle(phase: .momentum, x: 500, y: 0, edges: edges, canGoBack: true, canGoForward: true).commit == nil)
        }
    }

    @Test func pageConsumptionAndVerticalStartRejectWholeGesture() {
        for (x, y, edge) in [(20.0, 0.0, false), (3.0, 10.0, true), (10.0, 10.0, true)] {
            var swipe = HistorySwipe()
            #expect(!swipe.handle(phase: .began, x: x, y: y, edges: .init(back: edge, forward: edge), canGoBack: true, canGoForward: true).consumes)
            #expect(!swipe.handle(phase: .changed, x: 300, y: 0, edges: edges, canGoBack: true, canGoForward: true).consumes)
        }
    }

    @Test func zeroBeginWaitsForDirectionAndKeepsInitialEdges() {
        var swipe = HistorySwipe()
        _ = swipe.handle(phase: .began, x: 0, y: 0, edges: .init(back: false, forward: true), canGoBack: true, canGoForward: true)
        #expect(!swipe.handle(phase: .changed, x: 150, y: 0, edges: edges, canGoBack: true, canGoForward: true).consumes)
    }

    @Test func reversalCancellationAndMissingHistoryDoNotCommit() {
        var swipe = HistorySwipe()
        _ = swipe.handle(phase: .began, x: 100, y: 0, edges: edges, canGoBack: true, canGoForward: true)
        _ = swipe.handle(phase: .changed, x: -60, y: 0, edges: edges, canGoBack: true, canGoForward: true)
        #expect(swipe.handle(phase: .ended, x: 0, y: 0, edges: edges, canGoBack: true, canGoForward: true).commit == nil)
        _ = swipe.handle(phase: .began, x: 200, y: 0, edges: edges, canGoBack: true, canGoForward: true)
        #expect(swipe.handle(phase: .cancelled, x: 0, y: 0, edges: edges, canGoBack: true, canGoForward: true).commit == nil)
        #expect(!swipe.handle(phase: .began, x: 200, y: 0, edges: edges, canGoBack: false, canGoForward: true).consumes)
        #expect(!swipe.handle(phase: .unphased, x: 200, y: 0, edges: edges, canGoBack: true, canGoForward: true).consumes)
        #expect(!swipe.handle(phase: .momentum, x: 200, y: 0, edges: edges, canGoBack: true, canGoForward: true).consumes)
    }
}
