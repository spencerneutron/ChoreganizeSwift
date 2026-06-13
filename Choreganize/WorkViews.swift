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
    @FetchRequest(sortDescriptors: [SortDescriptor(\CDChore.name)]) private var chores: FetchedResults<CDChore>
    @FetchRequest(sortDescriptors: [SortDescriptor(\CDLockedDay.date)]) private var lockedDays: FetchedResults<CDLockedDay>
    var date: Date
    @State private var showConfirmation = false
    @State private var showDoneAlert = false

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
            Section(header: Text("\(weekdayName), \(dateText)")) {
                ForEach(dayChores, id: \.objectID) { chore in
                    ChoreRowView(chore: chore, locked: isLocked, date: date)
                }
            }
        }
        .listStyle(.insetGrouped)
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
