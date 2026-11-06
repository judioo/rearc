import XCTest
@testable import ReArc

/// P3.24: the media strip and call card titles' marquee.
final class MarqueeMotionTests: XCTestCase {
    func testTheMarqueeRestsThenCrawlsAndLoopsBackToItsStart() {
        let width = 200.0, overflow = 60.0
        XCTAssertEqual(MarqueeMotion.offset(elapsed: 0, textWidth: width, overflow: overflow), 0)
        XCTAssertEqual(MarqueeMotion.offset(elapsed: MarqueeMotion.pause - 0.1, textWidth: width, overflow: overflow), 0, "resting")
        XCTAssertEqual(MarqueeMotion.offset(elapsed: MarqueeMotion.pause + 1, textWidth: width, overflow: overflow),
                       MarqueeMotion.speed, accuracy: 0.001)
        let cycle = MarqueeMotion.pause + (width + MarqueeMotion.gap) / MarqueeMotion.speed
        XCTAssertEqual(MarqueeMotion.offset(elapsed: cycle + 0.5, textWidth: width, overflow: overflow), 0, "the repeat sits where the title began")
        XCTAssertLessThanOrEqual(MarqueeMotion.speed, 30, "slow enough to read")
    }

    func testOnlyAnOverlongActiveTitleScrollsAndNeverUnderReduceMotion() {
        XCTAssertTrue(MarqueeMotion.scrolls(overflow: 40, isActive: true, reduceMotion: false))
        XCTAssertFalse(MarqueeMotion.scrolls(overflow: 0, isActive: true, reduceMotion: false), "fits")
        XCTAssertFalse(MarqueeMotion.scrolls(overflow: 40, isActive: false, reduceMotion: false), "pointer elsewhere, other strips")
        XCTAssertFalse(MarqueeMotion.scrolls(overflow: 40, isActive: true, reduceMotion: true))
        XCTAssertEqual(MarqueeMotion.offset(elapsed: 10, textWidth: 100, overflow: 0), 0)
    }
}
