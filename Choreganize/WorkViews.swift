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

    private var isCompleted: Bool { model.isCompleted(chore, on: Date()) }

    var body: some View {
        Toggle(isOn: Binding(
            get: { isCompleted },
            set: { newValue in
                withAnimation(.easeInOut) {
                    if newValue {
                        model.recordCompletion(chore)
                    } else {
                        model.removeCompletionForToday(chore)
                    }
                }
            })) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(chore.name)
                            .fontWeight(.semibold)
                            .foregroundStyle(isCompleted ? .secondary : .primary)
                            .strikethrough(isCompleted)
                        Spacer()
                        if model.isOverdue(chore) && !isCompleted {
                            Image(systemName: "exclamationmark.circle.fill")
                                .foregroundStyle(.red)
                        }
                    }
                    lastLine
                }
                .padding(.vertical, 4)
            }
            .listRowInsets(EdgeInsets(top: 8, leading: 8, bottom: 8, trailing: 0))
    }
}

struct WorkHomeView: View {
    @EnvironmentObject var model: AppModel
    @State private var selectedDay: Weekday? = Weekday.today

    var body: some View {
        ZStack {
            if let day = selectedDay {
                DayView(day: day, onClose: { withAnimation(.easeInOut) { selectedDay = nil } })
                    .transition(.move(edge: .trailing))
            } else {
                WeekView(selectDay: { withAnimation(.easeInOut) { selectedDay = $0 } })
                    .transition(.move(edge: .leading))
            }
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
        .listStyle(.insetGrouped)
    }
}

struct DayView: View {
    @EnvironmentObject var model: AppModel
    var day: Weekday
    var onClose: () -> Void
    @State private var showConfirmation = false
    @State private var showDoneAlert = false

    var body: some View {
        List {
            ForEach(model.chores.filter { $0.assignedDay == day }) { chore in
                ChoreRowView(chore: chore)
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(day.displayName)
        .toolbar {
            ToolbarItem(placement: .navigationBarLeading) {
                Button(action: onClose) {
                    Label("Back", systemImage: "chevron.backward")
                }
            }
            ToolbarItem(placement: .navigationBarTrailing) {
                NavigationLink("History") { HistoryView(day: day) }
            }
            ToolbarItem(placement: .bottomBar) {
                Button("Done For Today") { showDoneAlert = true }
            }
        }
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
        .listStyle(.insetGrouped)
        .navigationTitle("History")
    }
}

#Preview {
    WorkHomeView()
        .environmentObject(AppModel())
}
