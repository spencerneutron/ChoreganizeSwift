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

    private var lastLine: some View {
        Group {
            if let last = chore.lastCompletion, let lastDate = last.date {
                HStack(spacing: 4) {
                    Text(lastDate.formatted(date: .abbreviated, time: .omitted))
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

    private var content: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(chore.name ?? "Untitled")
                .fontWeight(.medium)
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
    // Expose a range before and after today so the user can page through recent days.
    // weekDates returns stable start-of-day dates, today centered (index == includePast).
    private var dates: [Date] {
        Scheduling.weekDates(startingFrom: Date(), includePast: 6, includeFuture: 6)
    }

    // Today sits in the middle of the symmetric range. Optional because scrollPosition(id:)
    // drives it; starts on today.
    @State private var currentIndex: Int? = 6

    /// Index of today within `dates` (today is the middle of the range).
    private var todayIndex: Int {
        dates.firstIndex { Calendar.current.isDateInToday($0) } ?? 6
    }

    var body: some View {
        // A horizontal paging ScrollView replaces the old .page TabView (a
        // UIPageViewController that built neighbour pages off-screen and lost their inset).
        // The GeometryReader sizes each page to the SAFE-AREA-bounded container, so the day
        // list rests BELOW the top nav controls and ABOVE the home indicator — a full-window
        // page (containerRelativeFrame) otherwise trapped the first rows under the top
        // controls and collided the Done button with the switcher. One container = identical
        // insets on every page (D2 stays fixed). All iOS 17+.
        GeometryReader { geo in
            ScrollView(.horizontal) {
                LazyHStack(spacing: 0) {
                    ForEach(Array(dates.enumerated()), id: \.offset) { _, date in
                        DayPage(date: date)
                            // Each page == the safe-area-bounded container: gives the nested
                            // List its bounded width AND height (it scrolls vertically within).
                            .frame(width: geo.size.width, height: geo.size.height)
                    }
                }
                .scrollTargetLayout()
            }
            .scrollTargetBehavior(.paging)       // container-width snap == the old paged feel
            .scrollPosition(id: $currentIndex)    // track the centered day (chevrons + deep link)
            .defaultScrollAnchor(.center)         // first layout centers today (the middle page)
            .scrollIndicators(.hidden)
            // Paint the grouped background to the physical edges so the home-indicator band
            // and the device's rounded corners are never the window's black base.
            .background(Color(.systemGroupedBackground).ignoresSafeArea())
            // CG-05: a widget deep-link targets a today chore — snap back to today (the user
            // may have paged away) so the targeted page is the one that scrolls to it.
            .onChange(of: model.deepLinkChore) { _, target in
                if target != nil, (currentIndex ?? todayIndex) != todayIndex {
                    withAnimation { currentIndex = todayIndex }
                }
            }
            .overlay(alignment: .center) {
                let idx = currentIndex ?? todayIndex
                HStack {
                    if idx > 0 {
                        Image(systemName: "chevron.left")
                    }
                    Spacer()
                    if idx < dates.count - 1 {
                        Image(systemName: "chevron.right")
                    }
                }
                .font(.title2)
                .foregroundColor(.secondary)
                .padding(.horizontal, 6)
                .opacity(0.5)
                .allowsHitTesting(false)
                .animation(.easeInOut, value: idx)
            }
        }
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
    var date: Date
    @State private var showConfirmation = false
    @State private var showDoneAlert = false
    @State private var showLogSheet = false
    /// The chore a widget deep-link (CG-05) is briefly highlighting on this page.
    @State private var highlightedChore: UUID?

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
        guard isToday, let target else { return }
        if let match = dayChores.first(where: { $0.id == target }) {
            withAnimation { proxy.scrollTo(match.objectID, anchor: .center) }
            highlightedChore = target
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.2) {
                withAnimation { if highlightedChore == target { highlightedChore = nil } }
            }
        }
        model.deepLinkChore = nil   // consumed
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

        ScrollViewReader { proxy in
        List {
            let weekdayName = date.formatted(.dateTime.weekday(.wide))
            let dateText = date.formatted(date: .abbreviated, time: .omitted)
            let header = "\(weekdayName), \(dateText)"
            // The Hub "Group tasks by" preference (#60). `.none` (or an empty day) keeps the
            // single dated section; otherwise one section per group, the date riding the
            // first group's header so it stays visible (WeekView shows no date of its own).
            let groups = grouping == .none ? [] : grouping.sections(for: dayChores)
            if groups.isEmpty {
                Section(header: Text(header)) {
                    ForEach(dayChores, id: \.objectID) { chore in
                        ChoreRowView(chore: chore, locked: isLocked, date: date, highlighted: highlightedChore != nil && chore.id == highlightedChore)
                    }
                }
            } else {
                ForEach(Array(groups.enumerated()), id: \.element.id) { index, group in
                    Section {
                        ForEach(group.chores, id: \.objectID) { chore in
                            ChoreRowView(chore: chore, locked: isLocked, date: date, highlighted: highlightedChore != nil && chore.id == highlightedChore)
                        }
                    } header: {
                        if index == 0 {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(header).font(.headline).textCase(nil).foregroundStyle(.primary)
                                Text(group.title)
                            }
                        } else {
                            Text(group.title)
                        }
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
        .listStyle(.insetGrouped)
        // Inset the rows past the left/right paging chevrons WeekView overlays near the
        // edges. contentMargins REPLACES the default insetGrouped margin (~20pt), so this
        // must exceed it to actually add space — 32 clears the chevrons with a gap.
        // (Tunable: one number; the list background still spans full-width, no edge strip.)
        .contentMargins(.horizontal, 32, for: .scrollContent)
        // Float-over-content (#65): the switcher + Done button float at the bottom, so give
        // the list enough trailing room that its last row rests clear ABOVE them at the end
        // of the scroll, while mid-scroll content still slides UNDER the translucent glass.
        // No TOP margin — the single-container safe area positions the header below the bar.
        .contentMargins(.bottom, hasDayButton ? bottomClearanceWithButton : bottomClearanceNoButton, for: .scrollContent)
        .scrollIndicators(.hidden)   // hide the scroll bar; scrolling still works
        .sheet(isPresented: $showLogSheet) {
            LogCompletionSheet(date: date, chores: inScopeChores)
        }
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
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
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
