import Testing
import Foundation
import CoreGraphics
@testable import Choreganize

/// The section rim's geometry and timelines (the pure maths the shader mirrors).
struct SectionRimTests {
    // 100 x 60 card, radius 10: arcs 15.708 each, horizontal edges 80, vertical edges 40.
    private let size = CGSize(width: 100, height: 60)
    private let radius: CGFloat = 10
    private var perimeter: Double { 2 * 80 + 2 * 40 + 2 * Double.pi * 10 }
    private var arc: Double { Double.pi / 2 * 10 }

    private func s(_ x: Double, _ y: Double, rtl: Bool = false) -> Double {
        SectionRim.arcParameter(of: CGPoint(x: x, y: y), size: size, cornerRadius: radius, rightToLeft: rtl)
    }

    @Test func perimeterOfRoundedRect() {
        #expect(abs(SectionRim.perimeter(size: size, cornerRadius: radius) - perimeter) < 1e-9)
        // A circle: width = height = 2r.
        let circle = SectionRim.perimeter(size: CGSize(width: 20, height: 20), cornerRadius: 10)
        #expect(abs(circle - 2 * Double.pi * 10) < 1e-9)
    }

    @Test func arcStartsAtLowerTrailingCorner() {
        #expect(abs(s(100, 50)) < 1e-9)                              // where the BR arc begins
        #expect(abs(s(110, 50)) < 1e-9)                              // nearest point, from outside
        #expect(abs(s(100 - 10 + 7.0711, 50 + 7.0711) - (arc / 2) / perimeter) < 1e-6)   // corner's 45 degrees
    }

    @Test func arcAtMidEdgesLTR() {
        #expect(abs(s(50, 60) - (arc + 40) / perimeter) < 1e-9)                  // bottom
        #expect(abs(s(50, 70) - (arc + 40) / perimeter) < 1e-9)                  // from outside
        #expect(abs(s(0, 30) - (2 * arc + 80 + 20) / perimeter) < 1e-9)          // leading side
        #expect(abs(s(50, 0) - (3 * arc + 80 + 40 + 40) / perimeter) < 1e-9)     // top
        #expect(abs(s(100, 30) - (4 * arc + 160 + 40 + 20) / perimeter) < 1e-9)  // trailing side
    }

    @Test func arcAtCornersLTR() {
        let c: Double = 10 * (1 - 0.70710678)   // offset of a corner's 45 degree point from the card corner
        #expect(abs(s(c, 60 - c) - (arc + 80 + arc / 2) / perimeter) < 1e-6)                    // lower leading
        #expect(abs(s(c, c) - (2 * arc + 80 + 40 + arc / 2) / perimeter) < 1e-6)                // upper leading
        #expect(abs(s(100 - c, c) - (3 * arc + 160 + 40 + arc / 2) / perimeter) < 1e-6)         // upper trailing
    }

    @Test func rightToLeftMirrors() {
        // Start at the lower LEFT corner; the same parameter lands on the mirrored point.
        #expect(abs(s(0, 50, rtl: true)) < 1e-9)
        #expect(abs(s(50, 60, rtl: true) - s(50, 60)) < 1e-9)                    // bottom mid is symmetric
        #expect(abs(s(100, 30, rtl: true) - s(0, 30)) < 1e-9)                    // leading side is now the right
        #expect(abs(s(0, 30, rtl: true) - s(100, 30)) < 1e-9)
        for (x, y) in [(5.0, 55.0), (20.0, 0.0), (90.0, 10.0), (100.0, 40.0)] {
            #expect(abs(s(x, y) - s(100 - x, y, rtl: true)) < 1e-9)
        }
    }

    @Test func monotonicAlongPathAndRoundTrip() {
        var last = -1.0
        for i in 0..<400 {
            let t = Double(i) / 400
            let p = SectionRim.point(atArc: t, size: size, cornerRadius: radius)
            let back = SectionRim.arcParameter(of: p, size: size, cornerRadius: radius)
            #expect(abs(back - t) < 1e-6)
            #expect(back > last)
            last = back
            let q = SectionRim.point(atArc: t, size: size, cornerRadius: radius, rightToLeft: true)
            #expect(abs(q.x - (100 - p.x)) < 1e-9 && abs(q.y - p.y) < 1e-9)
        }
    }

    @Test func restingValues() {
        #expect(SectionRim.hairlineOpacity(fraction: 0) == 0)
        #expect(abs(SectionRim.hairlineOpacity(fraction: 1) - 0.60) < 1e-12)
        #expect(abs(SectionRim.hairlineOpacity(fraction: 0.5) - 0.425) < 1e-12)
        #expect(SectionRim.hairlineOpacity(fraction: 0.01) > 0.25)
        #expect(SectionRim.haloLevel(fraction: 0) == 0)
        #expect(abs(SectionRim.haloLevel(fraction: 1) - 0.14) < 1e-12)
        #expect(abs(SectionRim.haloLevel(fraction: 0.5) - 0.07) < 1e-12)
        let rest = SectionRim.rest(fraction: 0.4)
        #expect(rest.baseFill == 0.4 && rest.lineOpacity == 0 && rest.headOpacity == 0)
    }

    @Test func flourishKeyPoints() {
        let from = 0.5
        let before = SectionRim.flourish(at: 0.8, from: from)
        #expect(before.lineFill == 0 && before.headOpacity == 0)
        #expect(abs(before.lineOpacity - 0.65) < 1e-12)
        #expect(abs(before.baseOpacity - 0.3) < 1e-12 && before.baseFill == from)

        let mid = SectionRim.flourish(at: 3.3, from: from)
        #expect(abs(mid.lineFill - 0.5) < 1e-9)                      // smoothstep midpoint
        #expect(mid.headOpacity == 1)

        let done = SectionRim.flourish(at: 5.8, from: from)
        #expect(done.lineFill == 1 && done.headOpacity == 0)
        #expect(abs(done.haloLevel - 0.14) < 1e-12)

        let peak = SectionRim.flourish(at: 7.4, from: from)
        #expect(abs(peak.haloLevel - 0.40) < 1e-12)
        #expect(abs(peak.lineOpacity - 0.65) < 1e-12)

        let end = SectionRim.flourish(at: 8, from: from)
        #expect(end == SectionRim.rest(fraction: 1))
        #expect(SectionRim.flourish(at: 12, from: from) == end)
        // Nothing reaches past the peak between the key points.
        for i in 0...80 {
            let f = SectionRim.flourish(at: Double(i) / 10, from: from)
            #expect(f.haloLevel <= 0.40 + 1e-12 && f.lineFill >= 0 && f.lineFill <= 1)
        }
    }
}
