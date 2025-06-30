import SwiftUI

/// Presents a month grid with chore counts.
struct CalendarHomeView: View {
    @EnvironmentObject var model: AppModel
    @State private var month: Date = Date()

    private var calendar: Calendar { Calendar.current }

    private var monthStart: Date {
        calendar.date(from: calendar.dateComponents([.year, .month], from: month))!
    }

    private var days: [Date?] {
        let range = calendar.range(of: .day, in: .month, for: monthStart)!
        let firstWeekday = calendar.component(.weekday, from: monthStart)
        var items: [Date?] = Array(repeating: nil, count: firstWeekday - 1)
        for day in range {
            items.append(calendar.date(byAdding: .day, value: day - 1, to: monthStart)!)
        }
        while items.count % 7 != 0 { items.append(nil) }
        return items
    }

    private var choresByDate: [Date: [Chore]] {
        model.choresByDate(inMonth: monthStart)
    }

    private var weekInterval: DateInterval {
        calendar.dateInterval(of: .weekOfYear, for: Date())!
    }

    var body: some View {
        VStack {
            HStack {
                Button(action: { month = calendar.date(byAdding: .month, value: -1, to: month)! }) {
                    Image(systemName: "chevron.left")
                }
                Spacer()
                Text(monthStart, format: Date.FormatStyle().month(.wide).year())
                    .font(.title2)
                    .fontWeight(.semibold)
                Spacer()
                Button(action: { month = calendar.date(byAdding: .month, value: 1, to: month)! }) {
                    Image(systemName: "chevron.right")
                }
            }
            .padding(.horizontal)
            .animation(.easeInOut, value: month)

            let columns = Array(repeating: GridItem(.flexible()), count: 7)
            LazyVGrid(columns: columns, spacing: 8) {
                ForEach(calendar.shortWeekdaySymbols, id: \.self) { day in
                    Text(day)
                        .font(.caption)
                        .frame(maxWidth: .infinity)
                }
                ForEach(Array(days.enumerated()), id: \.offset) { _, date in
                    if let date {
                        DayCell(date: date,
                                chores: choresByDate[calendar.startOfDay(for: date)] ?? [],
                                inCurrentWeek: weekInterval.contains(date))
                    } else {
                        Color.clear
                            .frame(height: 40)
                    }
                }
            }.frame(maxHeight: .infinity, alignment: .top)
        }
        .toolbar(.hidden, for: .navigationBar)
    }
}

private struct DayCell: View {
    @EnvironmentObject var model: AppModel
    var date: Date
    var chores: [Chore]
    var inCurrentWeek: Bool

    private var completeCount: Int {
        chores.filter { model.isCompleted($0, on: date) }.count
    }

    private var incompleteCount: Int { chores.count - completeCount }
    private var isPast: Bool {
        Calendar.current.startOfDay(for: date) < Calendar.current.startOfDay(for: Date())
    }

    @ViewBuilder
    private var badgeViews: some View {
        if isPast {
            HStack(spacing: 2) {
                if completeCount > 0 {
                    Badge(count: completeCount, color: .green)
                }
                if incompleteCount > 0 {
                    Badge(count: incompleteCount, color: .red)
                }
            }
        } else if inCurrentWeek {
            HStack(spacing: 2) {
                if completeCount > 0 {
                    Badge(count: completeCount, color: .green)
                }
                if incompleteCount > 0 {
                    Badge(count: incompleteCount, color: .red)
                }
            }
        } else if chores.count > 0 {
            Badge(count: chores.count, color: .blue)
        }
    }

    var body: some View {
        ZStack {
            Text(String(Calendar.current.component(.day, from: date)))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            badgeViews
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
        }
        .padding(4)
        .frame(height: 40)
    }
}

private struct Badge: View {
    var count: Int
    var color: Color
    var body: some View {
        Text("\(count)")
            .font(.caption2)
            .foregroundColor(.white)
            .padding(4)
            .background(Circle().fill(color))
    }
}

#Preview {
    CalendarHomeView()
        .environmentObject(AppModel())
}

