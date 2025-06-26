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
                    lastLine
                }
            }
    }
}

struct WorkHomeView: View {
    @EnvironmentObject var model: AppModel
    @State private var selectedDay: Weekday? = Weekday.today

    var body: some View {
        if let day = selectedDay {
            DayView(day: day, onClose: { selectedDay = nil })
        } else {
            WeekView(selectDay: { selectedDay = $0 })
        }
    }
}

struct WeekView: View {
    @EnvironmentObject var model: AppModel
    var selectDay: (Weekday) -> Void

    var body: some View {
        List {
            ForEach(Weekday.allCases) { day in
                Section(header: Text(day.displayName)) {
                    ForEach(model.chores.filter { $0.assignedDay == day }) { chore in
                        Toggle(isOn: Binding(
                            get: { model.isCompleted(chore, on: Date()) },
                            set: { newValue in
                                if newValue {
                                    model.recordCompletion(chore)
                                } else {
                                    model.removeCompletionForToday(chore)
                                }
                            })) {
                                Text(chore.name)
                            }
                    }
                }
                .onTapGesture { selectDay(day) }
            }
        }
    }
}

struct DayView: View {
    @EnvironmentObject var model: AppModel
    var day: Weekday
    var onClose: () -> Void
    @State private var showConfirmation = false
    @State private var showDoneAlert = false

    var body: some View {
        VStack {
            HStack {
                Button("Back") { onClose() }
                Spacer()
                Text(day.displayName)
                Spacer()
                NavigationLink("History") {
                    HistoryView(day: day)
                }
            }
            .padding()

            List {
                ForEach(model.chores.filter { $0.assignedDay == day }) { chore in
                    ChoreRowView(chore: chore)
                }
            }
            Button("Done For Today") { showDoneAlert = true }
            .padding()
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
                return chore.assignedDay == day
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
        .navigationTitle("History")
    }
}

#Preview {
    WorkHomeView()
        .environmentObject(AppModel())
}
