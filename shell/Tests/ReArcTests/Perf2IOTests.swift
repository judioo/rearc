import AppKit
import Foundation
import Testing
@testable import ReArc

@MainActor
struct Perf2IOTests {
    @Test func faviconReadDoesNotBlockRenderingOrOverwriteAnEngineIcon() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("rearc-perf2-icons-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let image = NSImage(size: NSSize(width: 2, height: 2), flipped: false) { _ in true }
        let data = try #require(image.tiffRepresentation)
        try data.write(to: directory.appendingPathComponent(FaviconStore.fileName(for: "site.test")))
        let queue = DispatchQueue(label: "rearc.perf2.test-icons")
        queue.suspend()
        let store = FaviconStore(directory: directory, ioQueue: queue)
        let url = URL(string: "https://site.test")!
        // A blocked disk queue must not block a view's cache misses.
        for _ in 0..<10 { #expect(store.image(for: url) == nil) }
        #expect(store.store(data, for: url, persist: false))
        let fresh = try #require(store.image(for: url))
        queue.resume()
        await withCheckedContinuation { continuation in
            queue.async { DispatchQueue.main.async { continuation.resume() } }
        }
        #expect(store.image(for: url) === fresh, "a late disk read cannot replace the newer engine icon")
    }

}
