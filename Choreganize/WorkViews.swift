import SwiftUI

/// A single chore row showing completion state and last completion summary.
struct ChoreRowView: View {
    @EnvironmentObject var model: AppModel
    var chore: Chore

    private var lastLine: some View {
        Group {
            if let last = model.lastCompletion(for: chore) {
                HStack(spacing: 4) {
                    Text(last.date.formatted(date: .abbreviated, time: .omitted))
                    if let notes = last.notes, !notes.isEmpty {
                        Text("\u{2013} \(notes)")
                    }
                    if model.isOverdue(chore) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundColor(.red)
                    }
                }
                .font(.caption)
                .lineLimit(1)
                .truncationMode(.tail)
                .foregroundColor(model.isOverdue(chore) ? .red : .secondary)
            } else {
                Text("Never completed")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
    }

    var body: some View {
        Toggle(isOn: Binding(
            get: { model.isCompleted(chore, on: Date()) },
            set: { newValue in
                if newValue {
                    model.recordCompletion(chore)
                } else {
                    model.removeCompletionForToday(chore)
                }
            })) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(chore.name)
                        .fontWeight(.medium)
                    lastLine
                }
                .opacity(model.needsAttention(chore, on: Date()) ? 1 : 0.5)
            }
            .padding(.vertical, 4)
    }
}

struct WorkHomeView: View {
    @EnvironmentObject var model: AppModel
    @State private var path = NavigationPath()

    var body: some View {
        NavigationStack(path: $path) {
            WeekView(selectDay: { path.append($0) })
                .navigationDestination(for: Weekday.self) { day in
                    DayView(day: day)
                        .toolbar(.visible, for: .navigationBar)
                }
                .toolbar(.hidden, for: .navigationBar)
        }
    }
}

struct WeekView: View {
    @EnvironmentObject var model: AppModel
    var selectDay: (Weekday) -> Void

    // Expose a range before and after today so the user can page
    // through recent days.
    private var dates: [Date] {
        model.weekDates(startingFrom: Date(), includePast: 6, includeFuture: 6)
    }

    // Today sits in the middle of the range
    @State private var currentIndex: Int = 6

    var body: some View {
        TabView(selection: $currentIndex) {
            ForEach(Array(dates.enumerated()), id: \.offset) { index, date in
                DayPage(date: date, selectDay: selectDay)
                    .tag(index)
                    .task { await prefetch(for: index) }
            }
        }
        .tabViewStyle(.page(indexDisplayMode: .never))
    }

    /// Prefetch completion data for the visible day and nearby days.
    private func prefetch(for index: Int) async {
        let offsets = [-2, -1, 0, 1, 2]
        for offset in offsets {
            let idx = index + offset
            guard dates.indices.contains(idx) else { continue }
            _ = await model.loadCompletions(for: dates[idx])
        }
    }
}

/// Single day page used within the horizontally scrolling week view.
private struct DayPage: View {
    @EnvironmentObject var model: AppModel
    var date: Date
    var selectDay: (Weekday) -> Void

    private var weekday: Weekday {
        let index = Calendar.current.component(.weekday, from: date) - 1
        return Weekday.standardCases[index]
    }

    var body: some View {
        List {
            let weekdayName = date.formatted(.dateTime.weekday(.wide))
            let dateText = date.formatted(date: .abbreviated, time: .omitted)
            Section(header: Text("\(weekdayName), \(dateText)")) {
                ForEach(model.chores(for: date)) { chore in
                    ChoreRowView(chore: chore)
                }
            }
            .onTapGesture { selectDay(weekday) }
        }
        .listStyle(.insetGrouped)
    }
}

struct DayView: View {
    @EnvironmentObject var model: AppModel
    var day: Weekday
    @State private var showConfirmation = false
    @State private var showDoneAlert = false

    var body: some View {
        List {
            ForEach(model.chores.filter { $0.isDaily || $0.assignedDay == day }) { chore in
                ChoreRowView(chore: chore)
            }
        }
        .listStyle(.insetGrouped)
        .alert("Finish day?", isPresented: $showDoneAlert) {
            Button("Confirm") {
                withAnimation { showConfirmation = true }
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                    withAnimation { showConfirmation = false }
                }
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("Any incomplete chores will remain unfinished.")
        }
        .navigationTitle(day.displayName)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                NavigationLink("History") {
                    HistoryView(day: day)
                }
            }
            ToolbarItem(placement: .bottomBar) {
                Button("Done For Today") { showDoneAlert = true }
            }
        }
        .overlay(
            Group {
                if showConfirmation {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 80))
                        .foregroundColor(.green)
                        .transition(.scale)
                }
            }
        )
    }
}

struct HistoryView: View {
    @EnvironmentObject var model: AppModel
    var day: Weekday
    var body: some View {
        List {
            ForEach(model.completions.filter { completion in
                guard let chore = model.chores.first(where: { $0.id == completion.choreId }) else { return false }
                return chore.isDaily || chore.assignedDay == day
            }.sorted(by: { $0.date > $1.date })) { completion in
                if let chore = model.chores.first(where: { $0.id == completion.choreId }) {
                    VStack(alignment: .leading) {
                        Text(chore.name)
                            .font(.headline)
                        Text(completion.date.formatted(date: .abbreviated, time: .omitted))
                        if let notes = completion.notes, !notes.isEmpty {
                            Text(notes)
                                .font(.caption)
                        }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("History")
    }
}

#Preview {
    WorkHomeView()
        .environmentObject(AppModel())
}
