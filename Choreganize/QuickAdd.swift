import SwiftUI

// CG-26 / #127 — the Quick Add ghost. While a day's list scrolls, a translucent
// "New chore" row appears under the section nearest the middle of the screen
// and opens New Chore prefilled with that day and section.
//
// Every section ends in a fixed-height slot (its footer), and only the target
// slot draws the ghost, so nothing ever moves under the user's finger. The
// rules below are pure and unit-tested; the tracker keeps scroll-frame work
// out of `DayPage.body`.

// MARK: - Prefill

/// The New Chore form values a Quick Add ghost opens with.
struct ChorePrefill: Equatable {
    var isDaily = false
    var frequency: Frequency = .weekly
    var day: Weekday?
    var areaID: UUID?
    /// The ghost's subtitle and the sheet's context line ("Weekly on Tuesdays").
    var summary: String

    /// Maps a section to its prefill: the page's weekday plus the section's grouping.
    /// Sections that don't imply a frequency (Unscheduled, a room, No Room, no
    /// grouping) default to weekly.
    static func make(for key: WorkGrouping.Key, on date: Date,
                     calendar: Calendar = .current) -> ChorePrefill {
        let weekday = Weekday.standardCases[calendar.component(.weekday, from: date) - 1]
        let weekly = "Weekly on \(weekday.displayName)s"
        switch key {
        case .all, .unscheduled, .noArea:
            return ChorePrefill(day: weekday, summary: weekly)
        case .daily:
            return ChorePrefill(isDaily: true, day: weekday, summary: "Every day")
        case .frequency(let frequency):
            let summary = frequency == .weekly
                ? weekly : "\(frequency.rawValue.capitalized) on a \(weekday.displayName)"
            return ChorePrefill(frequency: frequency, day: weekday, summary: summary)
        case .area(let id, let name):
            return ChorePrefill(day: weekday, areaID: id, summary: "\(name) · \(weekday.displayName)s")
        }
    }
}

// MARK: - Rules

enum QuickAddRules {
    /// A vertical extent in the window's coordinate space.
    struct Span: Equatable {
        var minY: CGFloat
        var maxY: CGFloat
        var midY: CGFloat { (minY + maxY) / 2 }
    }

    /// Past and locked days never offer the ghost: adding a chore to a finished
    /// day would silently break its perfect day.
    static func offersGhost(on date: Date, isLocked: Bool, now: Date = Date(),
                            calendar: Calendar = .current) -> Bool {
        !isLocked && calendar.startOfDay(for: date) >= calendar.startOfDay(for: now)
    }

    /// Of the slots wholly inside `viewport`, the one whose middle is nearest the
    /// viewport's middle (ties go to the upper slot). Nil when none is on screen.
    static func target(slots: [String: Span], viewport: Span) -> String? {
        let midline = viewport.midY
        return slots
            .filter { $0.value.minY >= viewport.minY && $0.value.maxY <= viewport.maxY }
            .min { a, b in
                let da = abs(a.value.midY - midline), db = abs(b.value.midY - midline)
                return da == db ? a.value.minY < b.value.minY : da < db
            }?
            .key
    }
}

// MARK: - Tracker

/// Per-page scroll state for the ghost. Slot frames arrive every scroll frame, so
/// they live outside observation; views observe only `target`, `isScrolling` and
/// `hovered`, which change a few times per scroll.
@MainActor @Observable
final class QuickAddTracker {
    /// The slot nearest the midline.
    private(set) var target: String?
    /// True while the list moves and for `linger` after it settles.
    private(set) var isScrolling = false
    /// Mac: the slot under the pointer, which reveals its ghost on hover.
    var hovered: String?

    @ObservationIgnored private var slots: [String: QuickAddRules.Span] = [:]
    @ObservationIgnored private var viewport: QuickAddRules.Span?
    @ObservationIgnored private var hideTask: Task<Void, Never>?
    @ObservationIgnored let linger: Duration

    #if DEBUG
    /// Screenshots and design review: keep the ghost up without scrolling.
    @ObservationIgnored private let holds = ProcessInfo.processInfo.environment["CHOREGANIZE_QUICKADD_HOLD"]?.isEmpty == false
    #else
    private let holds = false
    #endif

    init(linger: Duration = .seconds(3)) {
        self.linger = linger
        if holds { isScrolling = true }
    }

    /// One ghost at a time: the hovered slot wins over the scroll target.
    func shows(_ id: String) -> Bool {
        if let hovered { return hovered == id }
        return isScrolling && target == id
    }

    func updateSlot(_ id: String, span: QuickAddRules.Span) {
        slots[id] = span
        retarget()
    }

    func removeSlot(_ id: String) {
        slots[id] = nil
        if hovered == id { hovered = nil }
        retarget()
    }

    func updateViewport(_ span: QuickAddRules.Span) {
        viewport = span
        retarget()
    }

    /// Called from `onScrollPhaseChange`. Horizontal paging belongs to the outer
    /// pager, so it never reaches here.
    func scrollMoved(_ moving: Bool) {
        guard !holds else { return }
        hideTask?.cancel()
        if moving {
            if !isScrolling { isScrolling = true }
        } else if isScrolling {
            hideTask = Task { [weak self, linger] in
                try? await Task.sleep(for: linger)
                guard !Task.isCancelled else { return }
                self?.isScrolling = false
            }
        }
    }

    private func retarget() {
        guard let viewport else { return }
        let next = QuickAddRules.target(slots: slots, viewport: viewport)
        if next != target { target = next }
    }
}

// MARK: - Views

/// A section's fixed-height footer slot. Always laid out; draws the ghost only
/// when it's the target (or hovered, or pinned visible), so rows never move.
struct QuickAddSlot: View {
    let id: String
    let prefill: ChorePrefill
    let tracker: QuickAddTracker
    /// Accessibility label target, e.g. "Kitchen" → "Add chore to Kitchen".
    var sectionName: String?
    /// An empty day shows its ghost at rest as the empty state.
    var title = "New chore"
    var pinned = false
    let action: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOver

    var body: some View {
        // VoiceOver users get a static button under every section: no scrolling needed.
        let visible = pinned || voiceOver || tracker.shows(id)
        ZStack {
            // Hidden ghosts leave the view (and the accessibility tree) entirely; the
            // fixed frame below keeps the slot's space either way.
            if visible {
                Button(action: action) {
                    QuickAddGhostRow(title: title, summary: prefill.summary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(sectionName.map { "Add chore to \($0)" } ?? title)
                .accessibilityHint(prefill.summary)
                .accessibilityIdentifier("quickAdd.\(id.isEmpty ? "day" : id)")
                .transition(reduceMotion
                            ? .opacity
                            : .opacity.combined(with: .offset(y: 6)).combined(with: .scale(scale: 0.98)))
            }
        }
        .animation(.easeOut(duration: 0.22), value: visible)
        .frame(maxWidth: .infinity)
        .frame(height: QuickAddGhostRow.height)
        #if os(iOS)
        // A list footer is inset to the row text and padded above and below; span the
        // card, and let the ghost use that padding rather than grow the gap further.
        .padding(.horizontal, -16)
        .padding(.vertical, -6)
        #endif
        .onGeometryChange(for: QuickAddRules.Span.self) { proxy in
            let frame = proxy.frame(in: .global)
            return QuickAddRules.Span(minY: frame.minY, maxY: frame.maxY)
        } action: { span in
            tracker.updateSlot(id, span: span)
        }
        .onDisappear { tracker.removeSlot(id) }
        #if os(macOS)
        .onHover { inside in
            if inside { tracker.hovered = id } else if tracker.hovered == id { tracker.hovered = nil }
        }
        #endif
    }
}

/// The ghost itself: a dashed placeholder the width of the section card. It's a
/// little shorter than a chore row (about 74 pt on iOS 26, 45 pt on the Mac), so it
/// reads as the next row without passing for one.
struct QuickAddGhostRow: View {
    let title: String
    let summary: String

    #if os(iOS)
    static let height: CGFloat = 58
    #else
    static let height: CGFloat = 42
    #endif

    private let radius: CGFloat = {
        if #available(iOS 26.0, macOS 26.0, *) { return 22 }
        return 12
    }()

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "plus.circle.fill")
                .font(.title2)
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                // The chore row's type (body name, caption detail). Explicit fonts and
                // colors: a list footer sets a smaller font and resolves the hierarchical
                // `.primary` to its own secondary style.
                Text(title)
                    .font(.body.weight(.medium))
                    .foregroundStyle(Color.primary)
                Text(summary)
                    .font(.caption)
                    .foregroundStyle(Color.secondary)
            }
            .lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity, minHeight: Self.height, maxHeight: Self.height)
        .contentShape(Rectangle())
        .background(RoundedRectangle(cornerRadius: radius, style: .continuous)
            .fill(Color.accentColor.opacity(0.07)))
        .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous)
            .strokeBorder(Color.accentColor.opacity(0.55),
                          style: StrokeStyle(lineWidth: 1.5, dash: [6, 4])))
    }
}
