import SwiftUI
import CoreData

/// A single chore row showing completion state and last completion summary.
struct ChoreRowView: View {
    @Environment(\.managedObjectContext) private var context
    @ObservedObject var chore: CDChore
    var showToggle: Bool = true
    /// When enabled the toggle is displayed in a completed state and cannot be changed.
    var locked: Bool = false
    /// The date represented by this row when determining completion status.
    var date: Date = Date()
    /// Briefly tinted when a widget deep-link (CG-05) targets this chore.
    var highlighted: Bool = false
    /// #59: resolves a Household completion's `completedBy` to a member name
    /// ("by Sydney"); returns nil for Solo, legacy, and the user's own completions.
    @ObservedObject private var completers = CompleterDirectory.shared

    private var lastLine: some View {
        Group {
            if let last = chore.lastCompletion, let lastDate = last.date {
                HStack(spacing: 4) {
                    Text(lastDate.formatted(date: .abbreviated, time: .omitted))
                    if let byName = completers.name(for: last.completedBy) {
                        Text("· by \(byName)")
                    }
                    if let notes = last.notes, !notes.isEmpty {
                        Text("\u{2013} \(notes)")
                    }
                    if chore.isOverdue() {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundColor(.red)
                    }
                }
                .font(.caption)
                .lineLimit(1)
                .truncationMode(.tail)
                .foregroundColor(chore.isOverdue() ? .red : .secondary)
            } else {
                Text("Never completed")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
    }

    /// CG-17 / #99 — the assignment chip's text: "You" for the current user,
    /// otherwise the member's directory name. `namesByID` is read directly
    /// (not `name(for:)`, which hides the current user by design for the
    /// "· by X" attribution line — here self must show as "You").
    private var assigneeTag: String? {
        guard let assignee = chore.assignee else { return nil }
        if chore.isAssignedToCurrentUser { return "You" }
        return completers.namesByID[assignee] ?? "Member"
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(chore.name ?? "Untitled")
                    .fontWeight(.medium)
                if let tag = assigneeTag {
                    Text(tag)
                        .font(.caption2)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Color(.tertiarySystemFill)))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            lastLine
        }
        .opacity(chore.needsAttention(on: date) ? 1 : 0.5)
    }

    var body: some View {
        Group {
            if showToggle {
                if locked {
                    Toggle(isOn: .constant(chore.isCompleted(on: date))) { content }
                        .disabled(true)
                } else {
                    Toggle(isOn: Binding(
                        get: { chore.isCompleted(on: date) },
                        set: { newValue in
                            if newValue {
                                chore.recordCompletion(on: date, in: context)
                            } else {
                                chore.removeCompletion(on: date, in: context)
                            }
                        })) {
                            content
                        }
                }
            } else {
                content
            }
        }
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.accentColor.opacity(highlighted ? 0.18 : 0))
                .padding(.vertical, 2)
                .padding(.horizontal, -8)
                .animation(.easeInOut(duration: 0.3), value: highlighted)
        )
    }
}

struct WorkHomeView: View {
    var body: some View {
        // The bar (scope / share / Hub) is owned solely by ContentView's NavigationStack.
        // We no longer also declare .toolbar(.hidden) here — the two conflicting
        // declarations made the top inset ambiguous (header clipped, controls inconsistent).
        WeekView()
    }
}

struct WeekView: View {
    @EnvironmentObject private var model: AppModel
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    #endif
    // Expose a range before and after today so the user can page through recent days.
    // weekDates returns stable start-of-day dates, today centered (index == includePast).
    private var dates: [Date] {
        Scheduling.weekDates(startingFrom: Date(), includePast: 6, includeFuture: 6)
    }

    // The focused day as an index into `dates`: the page on screen, or the RIGHT page of a
    // two-day spread. Pages are identified by this index (a spread by its right page's), so
    // the same value survives a switch between one page and a spread.
    // macOS NOTE: the Mac shell doesn't mount this view — trackpad momentum ignores
    // `.scrollTargetBehavior(.paging)` and two guided fixes fought the scroll system
    // (both backed out). MacWorkHomeView shows one day with explicit navigation instead.
    @State private var position = ScrollPosition(id: 6)
    @State private var focusIndex = 6
    #if os(iOS)
    /// The open iPhone Duo's day rail follows the pager through this (see `DayRail`).
    @State private var rail = DayRailTracker()
    #endif
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Narrowest content a side of a two-day spread may have; below it, one day fills the width.
    private static let minSpreadPageWidth: CGFloat = 360

    /// Index of today within `dates` (today is the middle of the range).
    private var todayIndex: Int {
        dates.firstIndex { Calendar.current.isDateInToday($0) } ?? 6
    }

    /// A day's page, or — one past either end of the range, which a spread can reach so
    /// every day has a page — a quiet note that there's nothing further. Only the focused
    /// page handles a widget deep link: a spread's left page may be about to make way for
    /// the spread that puts today on the right.
    @ViewBuilder
    private func spreadSide(_ index: Int, focused: Bool = true) -> some View {
        if dates.indices.contains(index) {
            DayPage(date: dates[index], handlesDeepLinks: focused)
        } else {
            EdgePage(isEarlier: index < 0)
        }
    }

    /// Two days side by side (the day before | the focused day) where there's room: a
    /// regular × regular size (iPad, iPhone Duo's inner display) and room for both sides'
    /// content once the fold and any side bar are taken out. Decided by size class and the
    /// container, never the device model.
    private func showsSpread(in geo: GeometryProxy, insets: EdgeInsets, sideBar: Bool) -> Bool {
        #if os(iOS)
        guard horizontalSizeClass == .regular, verticalSizeClass == .regular else { return false }
        let split = SpreadSplit(in: geo)
        let margins = Self.spreadMargins(insets, sideBar: sideBar)
        let leading = split.leadingWidth - margins.leading
        let trailing = geo.size.width - split.leadingWidth - split.gap - margins.trailing
        return min(leading, trailing) >= Self.minSpreadPageWidth
        #else
        false
        #endif
    }

    /// A spread's outer margins: beside the system's side bar (the open iPhone Duo, where it
    /// reports vertical bars) both pages step in by the bar's width, so they sit
    /// symmetrically and the side away from the bar gains a margin for the day rail. Any
    /// other horizontal inset (a notch, an iPad sidebar) is just padded clear of.
    private static func spreadMargins(_ insets: EdgeInsets, sideBar: Bool) -> EdgeInsets {
        guard sideBar else { return EdgeInsets(top: 0, leading: insets.leading, bottom: 0, trailing: insets.trailing) }
        let bar = max(insets.leading, insets.trailing)
        return EdgeInsets(top: 0, leading: bar, bottom: 0, trailing: bar)
    }

    /// The day rail never grows wider than this, whatever the inset beside it.
    private static let maxRailWidth: CGFloat = 88

    /// The two days a spread shows, for VoiceOver.
    private func spreadDescription(right index: Int) -> String {
        [index - 1, index]
            .filter { dates.indices.contains($0) }
            .map { dates[$0].formatted(.dateTime.weekday(.wide).month(.wide).day()) }
            .joined(separator: " and ")
    }

    /// Pages to a spread picked on the day rail (a drag, or VoiceOver's adjust).
    private func select(spread right: Int) {
        focusIndex = right
        if reduceMotion {
            position.scrollTo(id: right)
        } else {
            withAnimation(.snappy) { position.scrollTo(id: right) }
        }
    }

    /// Page IDs: each day's index, or in a spread each spread's right-page index (see
    /// `WeekPager.spreadRights`).
    private func pageIDs(spread: Bool) -> [Int] {
        spread ? WeekPager.spreadRights(focus: focusIndex, dayCount: dates.count) : Array(dates.indices)
    }

    var body: some View {
        // A horizontal paging ScrollView replaces the old .page TabView (a
        // UIPageViewController that built neighbour pages off-screen and lost their inset).
        // The GeometryReader sizes each page to the SAFE-AREA-bounded container, so the day
        // list rests BELOW the top nav controls and ABOVE the home indicator — a full-window
        // page (containerRelativeFrame) otherwise trapped the first rows under the top
        // controls and collided the Done button with the switcher. One container = identical
        // insets on every page (D2 stays fixed). iOS 18+ (ScrollPosition, scroll geometry).
        // Horizontally, each page spans the full width — under a side safe-area inset (iPhone
        // Duo's side bar, a notch in landscape) — and pads its own content clear of it. Pages
        // narrower than the scroll view left a neighbour's sliver under the bar, which
        // misaligned paging and made the leading-most page a neighbour. The outer reader
        // keeps the safe area so it can report the insets; the pager's ignores it.
        GeometryReader { outer in
            #if os(iOS)
            VerticalBarReader { barsAreVertical in
                pager(insets: outer.safeAreaInsets, sideBar: barsAreVertical)
            }
            #else
            pager(insets: outer.safeAreaInsets, sideBar: false)
            #endif
        }
    }

    /// `sideBar`: the system lays bars out vertically here (iPhone Duo), so a horizontal
    /// inset is its side bar.
    private func pager(insets: EdgeInsets, sideBar: Bool) -> some View {
        GeometryReader { geo in
            let spread = showsSpread(in: geo, insets: insets, sideBar: sideBar)
            let pageIDs = pageIDs(spread: spread)
            ScrollView(.horizontal) {
                LazyHStack(spacing: 0) {
                    ForEach(pageIDs, id: \.self) { index in
                        page(index, spread: spread,
                             insets: spread ? Self.spreadMargins(insets, sideBar: sideBar) : insets, in: geo)
                        // Each page == the safe-area-bounded container vertically: gives the
                        // nested List its bounded width AND height (it scrolls vertically within).
                        .frame(width: geo.size.width, height: geo.size.height)
                    }
                }
                .scrollTargetLayout()
            }
            // Snap to each page, one per swipe.
            .scrollTargetBehavior(.viewAligned(limitBehavior: .alwaysByOne))
            .scrollPosition($position)            // place the pager (layout switches, deep link)
            .defaultScrollAnchor(.center)         // first layout centers today (the middle page)
            .scrollIndicators(.hidden)
            // The focused page is where a scroll settles, read from the scroll offset. Only a
            // scroll that ran — a swipe, an animated scroll from VoiceOver, a keyboard or the
            // code below — moves it: layout passes (first launch, a resize when iPhone Duo
            // opens or rotates) shift the offset without a scroll phase, and the layout switch
            // below re-places the pager.
            .onScrollPhaseChange { oldPhase, phase, context in
                guard phase == .idle, oldPhase != .idle else { return }
                focusIndex = pageIDs[WeekPager.pageIndex(offset: context.geometry.contentOffset.x,
                                                         pageWidth: geo.size.width,
                                                         pageCount: pageIDs.count)]
            }
            // A new layout (opening or closing iPhone Duo, rotating, resizing an iPad window)
            // changes the page width, and may switch between one page and a spread, which
            // changes the page IDs. Neither keeps the offset on the focused day, so place the
            // pager explicitly: the day that was on screen stays on screen (as a spread's
            // right page), and a spread's right page becomes the single page.
            .onChange(of: PagerLayout(width: geo.size.width, spread: spread)) { _, layout in
                let index = WeekPager.pageID(switchingToSpread: layout.spread, focus: focusIndex,
                                             dayCount: dates.count)
                focusIndex = index
                position.scrollTo(id: index)
                #if os(iOS)
                if layout.spread { rail.rightIndex = CGFloat(index) }
                #endif
            }
            #if os(iOS)
            // The day rail tracks the pager continuously: the fractional spread on screen.
            .onScrollGeometryChange(for: CGFloat.self) { $0.contentOffset.x } action: { _, x in
                guard spread, let first = pageIDs.first else { return }
                rail.rightIndex = DayRailMath.rightIndex(firstRight: first, offset: x, pageWidth: geo.size.width)
            }
            // The open iPhone Duo: a spread beside a side bar gets the day rail in the margin
            // across from the bar.
            .overlay(alignment: insets.trailing >= insets.leading ? .leading : .trailing) {
                let bar = max(insets.leading, insets.trailing)
                if spread, sideBar, bar > 0 {
                    DayRail(dayCount: dates.count, tracker: rail, spreadRights: pageIDs,
                            focusedRight: focusIndex,
                            spreadDescription: { spreadDescription(right: $0) },
                            onSelect: { select(spread: $0) })
                        .frame(width: min(bar, Self.maxRailWidth))
                        .frame(width: bar)
                }
            }
            #endif
            // Paint the grouped background to the physical edges so the home-indicator band
            // and the device's rounded corners are never the window's black base.
            .background(Color.compatGroupedBackground.ignoresSafeArea())
            // CG-05: a widget deep-link targets a today chore — snap back to today (the user
            // may have paged away) so the targeted page is the one that scrolls to it. In a
            // spread today lands on the right, the page that stays when iPhone Duo closes.
            .onChange(of: model.deepLinkChore) { _, target in
                if target != nil,
                   let landing = WeekPager.deepLinkTarget(today: todayIndex, focus: focusIndex) {
                    focusIndex = landing
                    withAnimation { position.scrollTo(id: landing) }
                }
            }
        }
        .ignoresSafeArea(.container, edges: .horizontal)
    }

    /// A page: the focused day, plus — in a spread — the day before it on the left, divided
    /// where the device folds. The focused day keeps the same place in the view tree in both
    /// layouts, so switching (opening or closing iPhone Duo, resizing an iPad window) keeps
    /// its DayPage, with any open sheet, draft and list position, instead of rebuilding it.
    /// Each side is padded clear of the side safe-area insets it touches (a side bar, a
    /// notch) — in a spread, the mirrored `spreadMargins` — so its list and cards stop short
    /// of them; only the plain page background, painted by the pager, runs underneath.
    private func page(_ index: Int, spread: Bool, insets: EdgeInsets, in geo: GeometryProxy) -> some View {
        HStack(spacing: 0) {
            if spread {
                let split = SpreadSplit(in: geo)
                spreadSide(index - 1, focused: false)
                    .padding(.leading, insets.leading)
                    .frame(width: split.leadingWidth)
                Color.clear
                    .frame(width: split.gap)
            }
            spreadSide(index)
                .padding(.leading, spread ? 0 : insets.leading)
                .padding(.trailing, insets.trailing)
                .frame(maxWidth: .infinity)
        }
    }
}

/// The pager's layout: its page width, and whether it shows two-day spreads.
private struct PagerLayout: Equatable {
    var width: CGFloat
    var spread: Bool
}

/// The Work pager's page arithmetic, kept pure for unit tests. Days are indices into the
/// pager's range (`0 ..< dayCount`, today in the middle); a two-day spread is identified by
/// its right page, the focused day.
enum WeekPager {
    /// Right-page indices of the spreads: every other day, in step with the focused day, so
    /// a swipe moves two days and the focused day stays on the right. Reaching one past the
    /// end keeps every day in the range on some spread whichever parity is in step; the
    /// side that falls outside the range shows an `EdgePage`, never a day the single-page
    /// view can't reach (opened on the earliest day, the left page is that note).
    static func spreadRights(focus: Int, dayCount: Int) -> [Int] {
        Array(stride(from: focus.isMultiple(of: 2) ? 0 : 1, through: dayCount, by: 2))
    }

    /// The page to show after switching layout: the focused day becomes a spread's right
    /// page, and a spread's right page becomes the single page (one past the end, an edge
    /// note, falls back to the last day, the one that spread showed).
    static func pageID(switchingToSpread spread: Bool, focus: Int, dayCount: Int) -> Int {
        spread ? focus : min(focus, dayCount - 1)
    }

    /// Where a deep link to today lands, or `nil` when today is already the focused page.
    /// In a spread that's the right page, even when today is showing on the left: the right
    /// page is the one the outer display keeps when iPhone Duo closes. (The spreads then
    /// re-step around today.)
    static func deepLinkTarget(today: Int, focus: Int) -> Int? {
        focus == today ? nil : today
    }

    /// The page at a horizontal scroll offset, measured from the content's leading inset.
    static func pageIndex(offset: CGFloat, pageWidth: CGFloat, pageCount: Int) -> Int {
        guard pageWidth > 0, pageCount > 0 else { return 0 }
        return min(max(Int((offset / pageWidth).rounded()), 0), pageCount - 1)
    }
}

/// The side of a two-day spread that falls outside the pager's range (before the earliest
/// day or after the latest): a quiet note instead of a day the single-page view can't reach.
private struct EdgePage: View {
    let isEarlier: Bool

    var body: some View {
        Text(isEarlier ? "No earlier days" : "No later days")
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.compatGroupedBackground)
    }
}

/// Where a two-day spread divides. On iPhone Duo that's the fold: its division region
/// (iOS 27.1) is reported even while the device is flat, and covers the curve when the
/// device is partly folded, so each page keeps to one half and nothing sits in the fold.
/// The gap follows the region's frame whether or not it's active (Apple: "An inactive
/// region still has a frame, so you can leave room for it. This keeps your layout from
/// jumping"). Elsewhere the spread divides halfway.
private struct SpreadSplit {
    var leadingWidth: CGFloat
    var gap: CGFloat = 0

    init(in geo: GeometryProxy) {
        leadingWidth = geo.size.width / 2
        #if os(iOS)
        // Only a fold that runs down the middle of the container splits the spread; one
        // across it, or off to a side (Split View on the inner display), falls back to halves.
        if #available(iOS 27.1, *),
           let fold = geo.reservedRegions(kind: .division, options: .includeInactive).first,
           fold.frame.minX > geo.size.width / 4, fold.frame.maxX < geo.size.width * 3 / 4 {
            leadingWidth = fold.frame.minX
            gap = fold.frame.width
        }
        #endif
    }
}

/// Single day page used within the horizontally scrolling week view or as a
/// standalone view.
struct DayPage: View {
    @Environment(\.managedObjectContext) private var context
    @EnvironmentObject private var model: AppModel
    // Prefetches area/completions/household so rows don't fault them one-by-one on
    // the main thread (Work/Edit-open hang, cz_device10).
    @FetchRequest(fetchRequest: displayChoresFetchRequest()) private var chores: FetchedResults<CDChore>
    @FetchRequest(sortDescriptors: [SortDescriptor(\CDLockedDay.date)]) private var lockedDays: FetchedResults<CDLockedDay>
    @AppStorage(SettingsKeys.workGrouping) private var workGroupingRaw = WorkGrouping.none.rawValue
    /// #128: one-offs lead every upcoming day's list. Households are fetched so a
    /// synced change to the limit setting refreshes the section's ＋.
    @FetchRequest(fetchRequest: oneOffsFetchRequest()) private var oneOffs: FetchedResults<CDOneOff>
    @FetchRequest(sortDescriptors: []) private var households: FetchedResults<CDHousehold>
    @AppStorage(SettingsKeys.oneOffsUnlimitedPersonal) private var oneOffsUnlimitedPersonal = false
    @State private var oneOffSheet: OneOffEditor.Mode?
    var date: Date
    /// Whether this page acts on a widget deep link (CG-05). False for a two-day spread's
    /// left page, which is about to make way for the spread with today on the right.
    var handlesDeepLinks = true
    @State private var showConfirmation = false
    @State private var showDoneAlert = false
    @State private var showLogSheet = false
    /// #107: the check-off-with-a-photo sheet (today only, iOS 27 + Apple Intelligence).
    @State private var showPhotoCheck = false
    /// The chore a widget deep-link (CG-05) or a Quick Add save is briefly highlighting.
    @State private var highlightedChore: UUID?
    /// #127: where the Quick Add ghost is; read only by the section slots.
    @State private var quickAdd = QuickAddTracker()
    @State private var quickAddRequest: QuickAddRequest?

    // Bottom clearances for the floating chrome, scaled with Dynamic Type so larger text
    // still clears it — replaces the old raw 132 / 84 magic numbers. The list reserves more
    // room on days that show a Done/Unlock button so the last row clears that too.
    @ScaledMetric private var bottomClearanceWithButton: CGFloat = 110
    @ScaledMetric private var bottomClearanceNoButton: CGFloat = 72
    @ScaledMetric private var dayButtonClearance: CGFloat = 58

    private var grouping: WorkGrouping { WorkGrouping(rawValue: workGroupingRaw) ?? .none }

    private var isPast: Bool {
        Calendar.current.startOfDay(for: date) < Calendar.current.startOfDay(for: Date())
    }

    private var isToday: Bool { Calendar.current.isDateInToday(date) }

    /// Honors a widget deep-link (CG-05) that points at a chore on today's page: scrolls
    /// the row into view, flashes a highlight, and clears the request so it fires once.
    /// Only today's page acts — the widget links to today's chores; other days ignore it.
    @MainActor
    private func consumeDeepLink(_ target: UUID?, proxy: ScrollViewProxy, in dayChores: [CDChore]) {
        guard isToday, handlesDeepLinks, let target else { return }
        if let match = dayChores.first(where: { $0.id == target }) {
            withAnimation { proxy.scrollTo(match.objectID, anchor: .center) }
            highlightedChore = target
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.2) {
                withAnimation { if highlightedChore == target { highlightedChore = nil } }
            }
        }
        model.deepLinkChore = nil   // consumed
    }

    /// #127: scrolls to and flashes a chore the Quick Add sheet just saved, once
    /// the fetch has picked it up.
    @MainActor
    private func flashNewChore(_ chore: CDChore, proxy: ScrollViewProxy) {
        guard let id = chore.id else { return }
        let objectID = chore.objectID
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
            withAnimation { proxy.scrollTo(objectID, anchor: .center) }
            highlightedChore = id
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.2) {
                withAnimation { if highlightedChore == id { highlightedChore = nil } }
            }
        }
    }

    /// A section's Quick Add slot, or nothing on days that don't offer one.
    @ViewBuilder
    private func quickAddSlot(id: String, key: WorkGrouping.Key, sectionName: String?,
                              emptyDay: Bool, offered: Bool) -> some View {
        if offered {
            let prefill = ChorePrefill.make(for: key, on: date)
            QuickAddSlot(id: id, prefill: prefill, tracker: quickAdd, sectionName: sectionName,
                         title: emptyDay ? "Add a chore for \(date.formatted(.dateTime.weekday(.wide)))" : "New chore",
                         pinned: emptyDay) {
                quickAddRequest = QuickAddRequest(prefill: prefill)
            }
        }
    }

    var body: some View {
        let active = model.activeHousehold
        let scopedLocks = Array(lockedDays).inScope(active)
        let inScopeChores = Array(chores).inScope(active)
        let dayChores = Scheduling.chores(inScopeChores, for: date)
        let isLocked = DayLock.isLocked(date, in: scopedLocks)
        // CG-08 — the currently-visible, not-yet-done chores for this day. "Mark all
        // done" acts on exactly this set, so locked/past days (toggles disabled) and
        // already-completed rows are untouched.
        let incompleteChores = dayChores.filter { !$0.isCompleted(on: date) }
        // A Done (unlocked) or Unlock (locked, not past) button floats on every day except a
        // locked PAST day; reserve extra bottom room only when one is shown.
        let hasDayButton = !(isLocked && isPast)
        let offersQuickAdd = QuickAddRules.offersGhost(on: date, isLocked: isLocked)
        let bottomClearance = hasDayButton ? bottomClearanceWithButton : bottomClearanceNoButton
        // One-offs aren't tied to a day, so every upcoming page shows the same ones
        // (past pages are history). Hidden when there are none.
        let scopedOneOffs = Array(oneOffs).inScope(active)
        let showsOneOffs = !isPast && !scopedOneOffs.isEmpty
        let canAddOneOff = OneOffLimit.canAdd(
            existing: scopedOneOffs.count,
            unlimited: OneOffLimit.isUnlimited(household: active, personalUnlimited: oneOffsUnlimitedPersonal))

        ScrollViewReader { proxy in
        List {
            let weekdayName = date.formatted(.dateTime.weekday(.wide))
            let dateText = date.formatted(date: .abbreviated, time: .omitted)
            let header = "\(weekdayName), \(dateText)"
            // The Hub "Group tasks by" preference (#60). `.none` (or an empty day) keeps the
            // single dated section; otherwise one section per group, the date riding the
            // first group's header so it stays visible (WeekView shows no date of its own).
            let groups = grouping == .none ? [] : grouping.sections(for: dayChores)
            // #128: one-offs are the first section and take the date header with them.
            if showsOneOffs {
                OneOffsSection(oneOffs: scopedOneOffs, dateHeader: header, canAdd: canAddOneOff,
                               onAdd: { oneOffSheet = .new },
                               onEdit: { oneOffSheet = .edit($0) })
            }
            if groups.isEmpty {
                Section {
                    ForEach(dayChores, id: \.objectID) { chore in
                        ChoreRowView(chore: chore, locked: isLocked, date: date, highlighted: highlightedChore != nil && chore.id == highlightedChore)
                    }
                } header: {
                    if !showsOneOffs { Text(header) }
                } footer: {
                    quickAddSlot(id: "", key: .all, sectionName: nil,
                                 emptyDay: dayChores.isEmpty, offered: offersQuickAdd)
                }
            } else {
                ForEach(Array(groups.enumerated()), id: \.element.id) { index, group in
                    Section {
                        ForEach(group.chores, id: \.objectID) { chore in
                            ChoreRowView(chore: chore, locked: isLocked, date: date, highlighted: highlightedChore != nil && chore.id == highlightedChore)
                        }
                    } header: {
                        if index == 0 && !showsOneOffs {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(header).font(.headline).textCase(nil).foregroundStyle(.primary)
                                Text(group.title)
                            }
                        } else {
                            Text(group.title)
                        }
                    } footer: {
                        quickAddSlot(id: group.id, key: group.key, sectionName: group.title,
                                     emptyDay: false, offered: offersQuickAdd)
                    }
                }
            }

            // CG-08 — one tap to complete every visible incomplete chore for the day.
            // Only offered on an unlocked, non-empty day (locked days have disabled
            // toggles), and only while something is still incomplete.
            if !isLocked && !incompleteChores.isEmpty {
                Section {
                    Button {
                        let ids = Set(incompleteChores.map(\.objectID))
                        withAnimation {
                            BulkChoreOps.markAllDone(ids, on: date, in: context)
                        }
                    } label: {
                        Label("Mark all done", systemImage: "checklist.checked")
                    }
                    .accessibilityIdentifier("markAllDoneButton")
                    #if os(iOS)
                    // #107 — photograph a room; chores that look done come back pre-checked
                    // for the user to confirm. Today only: a photo shows the room now.
                    if isToday && RoomVisionAvailability.current.isAvailable {
                        Button {
                            showPhotoCheck = true
                        } label: {
                            Label("Check off with a photo", systemImage: "camera.viewfinder")
                        }
                        .accessibilityIdentifier("photoCheckButton")
                    }
                    #endif
                }
            }

            // #57 Part 2 — past days are auto-locked (DayLock.isLocked) so the row toggles
            // are disabled. This opens a checklist editor to add OR remove completions for
            // the day (the only way to fix a forgotten / mis-logged past completion).
            if isPast {
                Section {
                    Button {
                        showLogSheet = true
                    } label: {
                        Label("Log completions", systemImage: "checklist")
                    }
                    .accessibilityIdentifier("logCompletionButton")
                }
            }
        }
        .compatInsetGroupedList()
        #if os(iOS)
        // #127: each section's Quick Add slot is the gap between sections on days
        // that offer it, so the list adds no spacing of its own there.
        .listSectionSpacing(offersQuickAdd ? .custom(0) : .default)
        #endif
        // Wider than the default insetGrouped margin (~20pt): contentMargins REPLACES it.
        // 32 first cleared WeekView's paging chevrons (since removed) and is kept so the
        // cards don't shift; revisit with the day-paging review.
        // (Tunable: one number; the list background still spans full-width, no edge strip.)
        .contentMargins(.horizontal, 32, for: .scrollContent)
        // Float-over-content (#65): the switcher + Done button float at the bottom, so give
        // the list enough trailing room that its last row rests clear ABOVE them at the end
        // of the scroll, while mid-scroll content still slides UNDER the translucent glass.
        // No TOP margin — the single-container safe area positions the header below the bar.
        .contentMargins(.bottom, bottomClearance, for: .scrollContent)
        .scrollIndicators(.hidden)   // hide the scroll bar; scrolling still works
        // #127: the ghost shows while this list moves (the pager's horizontal swipes
        // don't reach here) and targets the slot nearest the visible middle.
        .onScrollPhaseChange { _, phase in
            quickAdd.scrollMoved(phase == .interacting || phase == .decelerating)
        }
        .onGeometryChange(for: QuickAddRules.Span.self) { proxy in
            let frame = proxy.frame(in: .global)
            return QuickAddRules.Span(minY: frame.minY, maxY: frame.maxY - bottomClearance)
        } action: { span in
            quickAdd.updateViewport(span)
        }
        .sheet(item: $quickAddRequest) { request in
            NewChoreView(prefill: request.prefill, offersOneOff: true) { chore in
                flashNewChore(chore, proxy: proxy)
            }
        }
        .sheet(item: $oneOffSheet) { mode in
            OneOffEditor(mode: mode)
        }
        .sheet(isPresented: $showLogSheet) {
            LogCompletionSheet(date: date, chores: inScopeChores)
        }
        #if os(iOS)
        .sheet(isPresented: $showPhotoCheck) {
            PhotoCheckView(date: date, chores: incompleteChores)
        }
        #endif
        .alert("Finish day?", isPresented: $showDoneAlert) {
            Button("Confirm") {
                DayLock.lock(date, existing: scopedLocks, household: active, in: context)
                withAnimation { showConfirmation = true }
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                    withAnimation { showConfirmation = false }
                }
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("Any incomplete chores will remain unfinished.")
        }
        .overlay(alignment: .center) {
            if showConfirmation {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 80))
                    .foregroundColor(.green)
                    .transition(.scale)
            }
        }
        .overlay(alignment: .bottom) {
            if isLocked && !isPast {
                Button("Unlock") { DayLock.unlock(date, existing: scopedLocks, in: context) }
                    .buttonStyle(.bordered)
                    .padding(.bottom, dayButtonClearance)
            } else if !isLocked {
                Button("Done") { showDoneAlert = true }
                    .buttonStyle(.borderedProminent)
                    .padding(.bottom, dayButtonClearance)
                    .onboardingAnchor(.doneButton)
            }
        }
        // CG-05: scroll to + flash the deep-linked chore. Both hooks matter — onChange
        // for when the link arrives while this page is already live, onAppear for when
        // the page mounts in response to the link (coming from Edit, or after WeekView
        // snaps back to today).
        .onChange(of: model.deepLinkChore) { _, target in
            consumeDeepLink(target, proxy: proxy, in: dayChores)
        }
        .onAppear {
            consumeDeepLink(model.deepLinkChore, proxy: proxy, in: dayChores)
        }
        }
    }
}

/// #127: a Quick Add ghost tap — opens New Chore with the section's prefill.
struct QuickAddRequest: Identifiable {
    let id = UUID()
    let prefill: ChorePrefill
}

/// Per-day completion editor for a (locked) past day (#57 Part 2). Past-day row
/// toggles are disabled, so this is the place to record OR remove what was actually
/// done on `date`. Shows every in-scope chore grouped by area and searchable; tapping
/// a row toggles its completion for the day. Completion state is mirrored into local
/// `@State` so the checkmarks update instantly (the managed objects aren't observed).
private struct LogCompletionSheet: View {
    let date: Date
    let chores: [CDChore]

    @Environment(\.dismiss) private var dismiss
    @Environment(\.managedObjectContext) private var context
    @State private var query = ""
    @State private var completedIDs: Set<NSManagedObjectID> = []

    private var filtered: [CDChore] {
        guard !query.isEmpty else { return chores }
        return chores.filter { ($0.name ?? "").localizedCaseInsensitiveContains(query) }
    }

    /// Grouped by area name, A→Z, with "No Area" last. Chores sorted by name within.
    private var groups: [(title: String, chores: [CDChore])] {
        let byArea = Dictionary(grouping: filtered) { $0.area?.name ?? "" }
        let sortChores: ([CDChore]) -> [CDChore] = { $0.sorted { ($0.name ?? "") < ($1.name ?? "") } }
        let named = byArea.filter { !$0.key.isEmpty }
            .sorted { $0.key < $1.key }
            .map { (title: $0.key, chores: sortChores($0.value)) }
        let noArea = byArea[""].map { [(title: "No Area", chores: sortChores($0))] } ?? []
        return named + noArea
    }

    private func toggle(_ chore: CDChore) {
        if completedIDs.contains(chore.objectID) {
            chore.removeCompletion(on: date, in: context)
            completedIDs.remove(chore.objectID)
        } else {
            chore.recordCompletion(on: date, in: context)
            completedIDs.insert(chore.objectID)
        }
    }

    var body: some View {
        NavigationStack {
            List {
                if chores.isEmpty {
                    ContentUnavailableView("No chores", systemImage: "checklist",
                                           description: Text("Add chores in the Edit tab first."))
                } else {
                    ForEach(groups, id: \.title) { group in
                        Section(group.title) {
                            ForEach(group.chores, id: \.objectID) { chore in
                                let done = completedIDs.contains(chore.objectID)
                                Button {
                                    toggle(chore)
                                } label: {
                                    HStack(spacing: 12) {
                                        Image(systemName: done ? "checkmark.circle.fill" : "circle")
                                            .foregroundStyle(done ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                                        Text(chore.name ?? "Untitled").foregroundStyle(.primary)
                                        Spacer()
                                    }
                                }
                                .accessibilityIdentifier("logRow-\(chore.name ?? "")")
                                .accessibilityAddTraits(done ? .isSelected : [])
                            }
                        }
                    }
                }
            }
            .searchable(text: $query, prompt: "Find a chore")
            .overlay {
                if !chores.isEmpty && filtered.isEmpty {
                    ContentUnavailableView.search(text: query)
                }
            }
            .navigationTitle(date.formatted(.dateTime.weekday(.abbreviated).month().day()))
            .compatInlineNavigationTitle()
            .toolbar {
                ToolbarItem(placement: .compatTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .compatMediumLargeDetents()
        .onAppear {
            completedIDs = Set(chores.filter { $0.isCompleted(on: date) }.map(\.objectID))
        }
    }
}

#if DEBUG
#Preview {
    WorkHomeView()
        .environment(\.managedObjectContext, PreviewStack.context)
        .environmentObject(AppModel())
}
#endif
