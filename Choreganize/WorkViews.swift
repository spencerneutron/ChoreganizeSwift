import SwiftUI

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
            Button("Done For Today") {
                for chore in model.chores.filter({ $0.assignedDay == day }) {
                    model.recordCompletion(chore)
                }
                withAnimation {
                    showConfirmation = true
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                    withAnimation {
                        showConfirmation = false
                    }
                }
            }
            .padding()
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
