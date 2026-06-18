import SwiftUI

/// A single chore row showing completion state and last completion summary.
struct ChoreRowView: View {
    @Environment(\.managedObjectContext) private var context
    @ObservedObject var chore: CDChore
    var showToggle: Bool = true
    /// When enabled the toggle is displayed in a completed state and cannot be changed.
    var locked: Bool = false
    /// The date represented by this row when determining completion status.
    var date: Date = Date()

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
    }
}

struct WorkHomeView: View {
    var body: some View {
        WeekView()
            .toolbar(.hidden, for: .navigationBar)
    }
}

struct WeekView: View {
    // Expose a range before and after today so the user can page
    // through recent days.
    private var dates: [Date] {
        Scheduling.weekDates(startingFrom: Date(), includePast: 6, includeFuture: 6)
    }

    // Today sits in the middle of the range
    @State private var currentIndex: Int = 6

    var body: some View {
        TabView(selection: $currentIndex) {
            ForEach(Array(dates.enumerated()), id: \.offset) { index, date in
                DayPage(date: date)
                    .tag(index)
            }
        }
        .tabViewStyle(.page(indexDisplayMode: .never))
        .overlay(alignment: .center) {
            HStack {
                if currentIndex > 0 {
                    Image(systemName: "chevron.left")
                }
                Spacer()
                if currentIndex < dates.count - 1 {
                    Image(systemName: "chevron.right")
                }
            }
            .font(.title2)
            .foregroundColor(.secondary)
            .padding(.horizontal, 6)
            .opacity(0.5)
            .allowsHitTesting(false)
            .animation(.easeInOut, value: currentIndex)
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

    private var grouping: WorkGrouping { WorkGrouping(rawValue: workGroupingRaw) ?? .none }

    private var isPast: Bool {
        Calendar.current.startOfDay(for: date) < Calendar.current.startOfDay(for: Date())
    }

    var body: some View {
        let active = model.activeHousehold
        let scopedLocks = Array(lockedDays).inScope(active)
        let dayChores = Scheduling.chores(Array(chores).inScope(active), for: date)
        let isLocked = DayLock.isLocked(date, in: scopedLocks)

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
                        ChoreRowView(chore: chore, locked: isLocked, date: date)
                    }
                }
            } else {
                ForEach(Array(groups.enumerated()), id: \.element.id) { index, group in
                    Section {
                        ForEach(group.chores, id: \.objectID) { chore in
                            ChoreRowView(chore: chore, locked: isLocked, date: date)
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
        }
        .listStyle(.insetGrouped)
        // Inset the rows past the left/right paging chevrons WeekView overlays near the
        // edges. contentMargins REPLACES the default insetGrouped margin (~20pt), so this
        // must exceed it to actually add space — 32 clears the chevrons with a gap.
        // (Tunable: one number; the list background still spans full-width, no edge strip.)
        .contentMargins(.horizontal, 32, for: .scrollContent)
        .scrollIndicators(.hidden)   // hide the scroll bar; scrolling still works
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
                    .padding(.bottom, 40)
            } else if !isLocked {
                Button("Done") { showDoneAlert = true }
                    .buttonStyle(.borderedProminent)
                    .padding(.bottom, 40)
                    .onboardingAnchor(.doneButton)
            }
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
