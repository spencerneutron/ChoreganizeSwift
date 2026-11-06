import SwiftUI

/// Wiring for the section rim (`SectionRim`, `SectionRimView`) on a day page: where each
/// section card sits, which sections earn a flourish, and the layer behind the List that
/// draws the rims. iOS only in use: the Mac's rows have no cards (docs/completion-wash/
/// BEHAVIOR.md §3.5).
extension SectionRim {
    /// The corner radius of an inset-grouped List section on this system. Measured in the
    /// iOS 27 Simulator (the card's 45° point sits 7.3 pt in from its corner, a 25 pt circle);
    /// before iOS 26 the cards used 10 pt. The cards' corners are continuous, the rim's
    /// circular: the two differ by well under a point.
    static var cardCornerRadius: CGFloat {
        if #available(iOS 26.0, macOS 26.0, *) { return 25 }
        return 10
    }
}

/// One section's rim state for a day page.
struct SectionRimSpec: Identifiable, Equatable {
    var id: String
    /// The section's rows (its chores' object IDs) in display order. The card is read from
    /// their frames in this order every time, so it never relies on an order recorded earlier.
    var rows: [AnyHashable]
    var fraction: Double
    var flourish: SectionRimFlourish?

    /// Section ids made unique: a repeated title gets "#1", "#2"… after its first use (or a
    /// higher number, when a room is itself named like that).
    static func uniqueIDs(_ ids: [String]) -> [String] {
        var used = Set<String>()
        var next: [String: Int] = [:]
        return ids.map { id in
            var candidate = id
            while used.contains(candidate) {
                let n = next[id, default: 1]
                next[id] = n + 1
                candidate = "\(id)#\(n)"
            }
            used.insert(candidate)
            return candidate
        }
    }
}

/// A section's flourish: when a local completion finished it, and its progress just before.
struct SectionRimFlourish: Equatable {
    var start: Date
    var from: Double
}

/// Which sections earn the rim's flourish (BEHAVIOR §3.4). Pure, for tests.
enum SectionRimTrigger {
    /// The sections that reached 100 % in this change because of the user's own action on the
    /// page (a completion within `WashTrigger.window`), with the progress each had before. A
    /// section finished by a sync, a widget, or on a locked day eases to 100 % instead, and a
    /// section with no earlier progress on record (it just appeared) is never celebrated.
    static func flourishes(old: [String: Double], new: [String: Double], isLocked: Bool,
                           lastLocalCompletion: Date?, now: Date) -> [String: Double] {
        guard !isLocked, let last = lastLocalCompletion else { return [:] }
        let age = now.timeIntervalSince(last)
        guard age >= 0 && age <= WashTrigger.window else { return [:] }
        var result: [String: Double] = [:]
        for (id, fraction) in new where fraction >= 1 {
            if let before = old[id], before < 1 { result[id] = before }
        }
        return result
    }
}

/// Where each section card sits on screen, collected from its rows' backgrounds: an
/// inset-grouped section card is the union of its rows. Frames are global, so they need no
/// coordinate space shared across the List's cells; the rim layer subtracts its own origin.
/// Frames are keyed by row alone: which section a row is in, and where in it, comes from the
/// current `SectionRimSpec` when the card is read.
@Observable
final class SectionRimTracker {
    private struct Entry: Equatable {
        var frame: CGRect
        /// The background view that reported it, so a view that goes away can't remove the
        /// frame a newer view of the same row has just reported.
        var reporter: UUID
    }

    private var frames: [AnyHashable: Entry] = [:]
    /// The rim layer's own global origin.
    var origin: CGPoint = .zero

    func update(row: AnyHashable, frame: CGRect, reporter: UUID) {
        let entry = Entry(frame: frame, reporter: reporter)
        if frames[row] == entry { return }
        frames[row] = entry
    }

    func remove(row: AnyHashable, reporter: UUID) {
        if frames[row]?.reporter == reporter { frames[row] = nil }
    }

    /// The section card's global rect, or nil while none of its rows is on screen.
    func cardFrame(rows: [AnyHashable]) -> CGRect? {
        Self.cardFrame(ordered: rows.map { frames[$0]?.frame })
    }

    /// The section card from its rows' frames in display order (nil = not measured: the List
    /// creates only the cells near the screen). Rows of a card abut, so the card is read from
    /// the longest run of measured rows that sit flush one under the next; a frame that
    /// doesn't (a row that has moved, or scrolled away, and hasn't reported since) counts as
    /// unmeasured. Rows outside the run are added at the run's average row height, so a long
    /// card keeps its proportions while it scrolls.
    static func cardFrame(ordered frames: [CGRect?]) -> CGRect? {
        let tolerance: CGFloat = 1.5
        var best: Range<Int>?
        var runStart: Int?
        for index in frames.indices {
            guard let frame = frames[index] else { runStart = nil; continue }
            let continues = runStart != nil && frames[index - 1].map {
                abs(frame.minY - $0.maxY) <= tolerance && abs(frame.minX - $0.minX) <= tolerance
            } == true
            if !continues { runStart = index }
            let begin = runStart ?? index
            if index - begin + 1 > (best?.count ?? 0) { best = begin..<(index + 1) }
        }
        guard let run = best else { return nil }
        let measured = run.compactMap { frames[$0] }
        let union = measured.dropFirst().reduce(measured[0]) { $0.union($1) }
        let average = union.height / CGFloat(run.count)
        let above = CGFloat(run.lowerBound) * average
        let below = CGFloat(frames.count - run.upperBound) * average
        return CGRect(x: union.minX, y: union.minY - above,
                      width: union.width, height: union.height + above + below)
    }
}

extension View {
    /// A chore row's background on a day page: the card colour (what the List paints by
    /// default), measured for the section's rim. No-op on the Mac, which has no cards.
    @ViewBuilder
    func sectionRimRow(_ tracker: SectionRimTracker, row: AnyHashable) -> some View {
        #if os(iOS)
        listRowBackground(SectionRimRowBackground(tracker: tracker, row: row))
        #else
        self
        #endif
    }
}

#if os(iOS)
/// Paints a chore row's card background and reports where it is.
private struct SectionRimRowBackground: View {
    let tracker: SectionRimTracker
    let row: AnyHashable
    @State private var reporter = UUID()

    var body: some View {
        Color.compatCardBackground
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame in
                tracker.update(row: row, frame: frame, reporter: reporter)
            }
            .onDisappear { tracker.remove(row: row, reporter: reporter) }
    }
}
#endif

/// The rims of a day page's section cards, drawn behind the List (so they only ever show
/// outside the opaque cards). Positions follow the cards as the List scrolls.
struct SectionRimLayer: View {
    let tracker: SectionRimTracker
    let sections: [SectionRimSpec]

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.clear
            ForEach(sections) { section in
                if let card = tracker.cardFrame(rows: section.rows) {
                    SectionRimView(cardSize: card.size, cornerRadius: SectionRim.cardCornerRadius,
                                   fraction: section.fraction,
                                   flourishStart: section.flourish?.start,
                                   flourishFrom: section.flourish?.from ?? 0)
                        .position(x: card.midX - tracker.origin.x, y: card.midY - tracker.origin.y)
                }
            }
        }
        .onGeometryChange(for: CGPoint.self) { $0.frame(in: .global).origin } action: { origin in
            tracker.origin = origin
        }
        // The List clips its cards at its edges (under the top controls, the home indicator,
        // the fold); the rims of cards running past them are clipped there too.
        .clipped()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
