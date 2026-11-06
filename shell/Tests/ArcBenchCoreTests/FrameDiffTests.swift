import Testing
@testable import ArcBenchCore

struct FrameDiffTests {
    let settings = DiffSettings(channelThreshold: 24, stride: 1, areaThreshold: 0.002)

    @Test func identicalFramesDoNotDiffer() {
        let frame = Frame.solid(width: 40, height: 20, b: 10, g: 20, r: 30)
        #expect(FrameDiff.changedFraction(frame, frame, settings: settings) == 0)
    }

    @Test func channelThresholdIsStrict() {
        let a = Frame.solid(width: 10, height: 10, b: 100, g: 100, r: 100)
        let within = Frame.solid(width: 10, height: 10, b: 124, g: 100, r: 100)
        let beyond = Frame.solid(width: 10, height: 10, b: 100, g: 100, r: 125)
        #expect(FrameDiff.changedFraction(a, within, settings: settings) == 0)
        #expect(FrameDiff.changedFraction(a, beyond, settings: settings) == 1)
    }

    @Test func alphaIsIgnored() {
        let a = Frame.solid(width: 4, height: 4, b: 0, g: 0, r: 0)
        var b = a
        for index in stride(from: 3, to: b.pixels.count, by: 4) { b.pixels[index] = 0 }
        #expect(FrameDiff.changedFraction(a, b, settings: settings) == 0)
    }

    @Test func fractionCountsChangedPixels() {
        let a = Frame.solid(width: 100, height: 100, b: 0, g: 0, r: 0)
        var b = a
        b.fill(x: 0 ..< 10, y: 0 ..< 10, b: 255, g: 255, r: 255)
        #expect(FrameDiff.changedFraction(a, b, settings: settings) == 0.01)
        #expect(settings.differs(0.01))
        #expect(!settings.differs(0.002))
    }

    @Test func regionRestrictsTheDiff() {
        let a = Frame.solid(width: 100, height: 50, b: 0, g: 0, r: 0)
        var b = a
        // A change in the sidebar column only.
        b.fill(x: 0 ..< 20, y: 0 ..< 50, b: 200, g: 200, r: 200)
        #expect(FrameDiff.changedFraction(a, b, in: .sidebar(0.2), settings: settings) == 1)
        #expect(FrameDiff.changedFraction(a, b, in: .content(0.2), settings: settings) == 0)
        #expect(FrameDiff.changedFraction(a, b, in: .window, settings: settings) == 0.2)
    }

    @Test func strideSamplesEveryNthPixel() {
        let a = Frame.solid(width: 8, height: 8, b: 0, g: 0, r: 0)
        var b = a
        // Odd columns only: invisible at stride 2 (columns 0, 2, 4, 6).
        for column in stride(from: 1, to: 8, by: 2) { b.fill(x: column ..< column + 1, y: 0 ..< 8, b: 255, g: 255, r: 255) }
        #expect(FrameDiff.changedFraction(a, b, settings: DiffSettings(stride: 2)) == 0)
        #expect(FrameDiff.changedFraction(a, b, settings: DiffSettings(stride: 1)) == 0.5)
    }

    @Test func rowPaddingIsSkipped() {
        // bytesPerRow 48 for a 10-pixel row: the padding differs, the pixels do not.
        var pa = [UInt8](repeating: 0, count: 48 * 2)
        var pb = pa
        for index in 40 ..< 48 { pa[index] = 0; pb[index] = 255 }
        let a = Frame(width: 10, height: 2, bytesPerRow: 48, pixels: pa)
        let b = Frame(width: 10, height: 2, bytesPerRow: 48, pixels: pb)
        #expect(FrameDiff.changedFraction(a, b, settings: settings) == 0)
    }

    @Test func differentSizesCountAsChanged() {
        let a = Frame.solid(width: 10, height: 10, b: 0, g: 0, r: 0)
        let b = Frame.solid(width: 12, height: 10, b: 0, g: 0, r: 0)
        #expect(FrameDiff.changedFraction(a, b, settings: settings) == 1)
    }

    @Test(arguments: [
        ("window", Region.window),
        ("sidebar", Region.sidebar(0.25)),
        ("content", Region.content(0.25)),
        ("0.1,0.2,0.5,1", Region(x0: 0.1, y0: 0.2, x1: 0.5, y1: 1)),
    ])
    func regionsParse(pair: (String, Region)) {
        #expect(Region.parse(pair.0, sidebarFraction: 0.25) == pair.1)
    }

    @Test(arguments: ["", "0.5,0,0.4,1", "0,0,1", "0,0,1.5,1", "middle"])
    func badRegionsAreRejected(text: String) {
        #expect(Region.parse(text, sidebarFraction: 0.25) == nil)
    }

    @Test func pixelRangesNeverEmpty() {
        let tiny = Region(x0: 0.5, y0: 0.5, x1: 0.5001, y1: 0.5001)
        let ranges = tiny.pixelRanges(width: 10, height: 10)
        #expect(ranges.x == 5 ..< 6)
        #expect(ranges.y == 5 ..< 6)
        #expect(Region.window.pixelRanges(width: 7, height: 3) == (0 ..< 7, 0 ..< 3))
    }
}
