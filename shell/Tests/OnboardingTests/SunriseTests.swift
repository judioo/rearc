import CoreGraphics
@testable import Onboarding
import XCTest

final class SunriseTests: XCTestCase {
    let L = MarkLayout(size: CGSize(width: 1440, height: 900))

    func assertClose(_ a: CGPoint, _ b: CGPoint, _ label: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(a.x, b.x, accuracy: 0.01, label, file: file, line: line)
        XCTAssertEqual(a.y, b.y, accuracy: 0.01, label, file: file, line: line)
    }

    /// Every take lands on the brand mark itself, just before and after it ends.
    func testEveryTakeEndsOnTheMark() {
        for v in SunriseVariant.allCases {
            let end = SunriseCues.of(v).end
            let f = SunriseTimeline.frame(v, end - 1e-6, L)
            let label = v.rawValue
            assertClose(f.arch.center, L.archCenter, label)
            XCTAssertEqual(f.arch.radius, L.archRadius, accuracy: 0.01, label)
            XCTAssertEqual(f.arch.width, L.archWidth, accuracy: 0.01, label)
            XCTAssertEqual(f.arch.navy?.lowerBound ?? 0, -142, accuracy: 0.01, label)
            XCTAssertEqual(f.arch.navy?.upperBound ?? 0, -94, accuracy: 0.01, label)
            XCTAssertEqual(f.arch.blue?.lowerBound ?? 0, -104, accuracy: 0.01, label)
            XCTAssertEqual(f.arch.blue?.upperBound ?? 0, -38, accuracy: 0.01, label)
            XCTAssertEqual(f.arch.colorMix, 1, accuracy: 1e-6, label)
            assertClose(f.sun.center, L.sunCenter, label)
            XCTAssertEqual(f.sun.radius, L.sunRadius, accuracy: 0.01, label)
            XCTAssertEqual(f.dawn, 1, accuracy: 1e-6, label)
            XCTAssertEqual(f.veil, 1, accuracy: 1e-6, label)
            XCTAssertEqual(SunriseTimeline.frame(v, end + 5, L), SunriseTimeline.finalFrame(L), label)
        }
    }

    /// The mark's construction (brand/CONCEPTS.md §4) on a 1440 x 900 canvas.
    func testLayoutMatchesTheGrid() {
        XCTAssertEqual(L.archRadius / L.sunRadius, 380.0 / 225.0, accuracy: 1e-9)
        XCTAssertEqual(L.sunOrbit, hypot(L.sunCenter.x - L.archCenter.x, L.sunCenter.y - L.archCenter.y), accuracy: 0.01)
        XCTAssertLessThan(L.markBottom + 900 * 0.19, 900 * 0.95, "Begin stays on screen")
    }

    func testTheSkyOnlyEverGetsLighter() {
        for v in SunriseVariant.allCases {
            var last = -1.0
            for i in 0 ... 240 {
                let d = SunriseTimeline.dawn(v, Double(i) * 0.05)
                XCTAssertGreaterThanOrEqual(d, last - 1e-9, v.rawValue)
                XCTAssertTrue((0 ... 1).contains(d), v.rawValue)
                last = d
            }
        }
    }

    func testStartsFromTheDesktop() {
        for v in SunriseVariant.allCases {
            let f = SunriseTimeline.frame(v, 0, L)
            XCTAssertEqual(f.veil, 0, v.rawValue)
            XCTAssertEqual(f.text, 0, v.rawValue)
            XCTAssertEqual(f.button, 0, v.rawValue)
        }
    }

    /// The ember is visible: it sits above the arch band, not behind it.
    func testTheEmberClearsTheArch() {
        let f = SunriseTimeline.frame(.ember, 3.2, L)
        let bandTop = L.archCenter.y - L.archRadius - L.archWidth / 2
        XCTAssertLessThan(f.sun.center.y + f.sun.radius, bandTop)
    }

    func testTheScoreIsAudibleAndNeverClips() {
        for v in SunriseVariant.allCases {
            let synth = SunriseSynth(variant: v)
            let n = 4800
            var l = [Float](repeating: 0, count: n), r = l
            var peak: Float = 0, energy: Float = 0
            synth.seek(to: SunriseCues.of(v).chime) // the fullest moment
            l.withUnsafeMutableBufferPointer { lp in
                r.withUnsafeMutableBufferPointer { rp in
                    synth.render(frames: n, left: lp.baseAddress!, right: rp.baseAddress!)
                }
            }
            for i in 0 ..< n {
                XCTAssertTrue(l[i].isFinite && r[i].isFinite)
                peak = max(peak, abs(l[i]), abs(r[i]))
                energy += l[i] * l[i]
            }
            XCTAssertLessThan(peak, 0.9, v.rawValue)
            XCTAssertGreaterThan(energy / Float(n), 1e-4, v.rawValue)
        }
    }
}
