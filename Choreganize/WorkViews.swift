import SwiftUI

/// A single chore row showing completion state and last completion summary.
struct ChoreRowView: View {
    @EnvironmentObject var model: AppModel
    var chore: Chore
    var showToggle: Bool = true
    /// When enabled the toggle is displayed in a completed state and cannot be changed.
    var locked: Bool = false
    /// The date represented by this row when determining completion status.
    var date: Date = Date()

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

    private var content: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(chore.name)
                .fontWeight(.medium)
            lastLine
        }
        .opacity(model.needsAttention(chore, on: date) ? 1 : 0.5)
    }

    var body: some View {
        Group {
            if showToggle {
                if locked {
                    Toggle(isOn: .constant(model.isCompleted(chore, on: date))) { content }
                        .disabled(true)
                } else {
                    Toggle(isOn: Binding(
                        get: { model.isCompleted(chore, on: date) },
                        set: { newValue in
                            if newValue {
                                model.recordCompletion(chore, date: date)
                            } else {
                                model.removeCompletion(chore, on: date)
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
    @EnvironmentObject var model: AppModel

    var body: some View {
        WeekView()
            .toolbar(.hidden, for: .navigationBar)
    }
}

struct WeekView: View {
    @EnvironmentObject var model: AppModel

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
                DayPage(date: date)
                    .tag(index)
                    .task { await prefetch(for: index) }
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
    @State private var showConfirmation = false
    @State private var showDoneAlert = false
    
    private var isPast: Bool {
        Calendar.current.startOfDay(for: date) < Calendar.current.startOfDay(for: Date())
    }

    var body: some View {
        let isLocked = isPast || model.isDayLocked(date)

        List {
            let weekdayName = date.formatted(.dateTime.weekday(.wide))
            let dateText = date.formatted(date: .abbreviated, time: .omitted)
            Section(header: Text("\(weekdayName), \(dateText)")) {
                ForEach(model.chores(for: date)) { chore in
                    ChoreRowView(chore: chore, locked: isLocked, date: date)
                }
            }
        }
        .listStyle(.insetGrouped)
        .task { let _ = await model.loadCompletions(for: date) }
        .alert("Finish day?", isPresented: $showDoneAlert) {
            Button("Confirm") {
                model.lockDay(date)
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
                Button("Unlock") { model.unlockDay(date) }
                    .buttonStyle(.bordered)
                    .padding(.bottom, 40)
            } else if !isLocked && !model.chores(for: date).isEmpty {
                Button("Done") { showDoneAlert = true }
                    .buttonStyle(.borderedProminent)
                    .padding(.bottom, 40)
            }
        }
    }
}

#Preview {
    WorkHomeView()
        .environmentObject(AppModel())
}
