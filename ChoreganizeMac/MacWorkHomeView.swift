import SwiftUI

/// The Mac Work surface: one day at a time with explicit navigation — the
/// structural answer to macOS trackpad momentum ignoring paged scrolling
/// (two guided-scroll attempts fought the system and were backed out; see
/// the note in WeekView). The shared `DayPage` renders the day; Previous /
/// Today / Next live in the toolbar with ⌘← / ⌘→ shortcuts, and day changes
/// slide in the direction of travel.
struct MacWorkHomeView: View {
    @EnvironmentObject private var model: AppModel

    /// Same symmetric 13-day window the iOS WeekView pages over.
    private var dates: [Date] {
        Scheduling.weekDates(startingFrom: Date(), includePast: 6, includeFuture: 6)
    }
    @State private var index = 6
    /// Direction of the last step, for the slide transition (+1 = forward).
    @State private var direction = 1

    private var todayIndex: Int {
        dates.firstIndex { Calendar.current.isDateInToday($0) } ?? 6
    }

    var body: some View {
        ZStack {
            DayPage(date: dates[min(max(index, 0), dates.count - 1)])
                .id(index)
                .transition(.asymmetric(
                    insertion: .move(edge: direction >= 0 ? .trailing : .leading).combined(with: .opacity),
                    removal: .move(edge: direction >= 0 ? .leading : .trailing).combined(with: .opacity)))
        }
        .background(Color.compatGroupedBackground.ignoresSafeArea())
        .toolbar {
            ToolbarItemGroup(placement: .compatTrailing) {
                Button {
                    step(-1)
                } label: {
                    Label("Previous Day", systemImage: "chevron.left")
                }
                .keyboardShortcut(.leftArrow, modifiers: .command)
                .disabled(index == 0)
                .help("Previous day (⌘←)")

                Button("Today") { jumpToToday() }
                    .disabled(index == todayIndex)
                    .help("Back to today")

                Button {
                    step(1)
                } label: {
                    Label("Next Day", systemImage: "chevron.right")
                }
                .keyboardShortcut(.rightArrow, modifiers: .command)
                .disabled(index == dates.count - 1)
                .help("Next day (⌘→)")
            }
        }
        // A widget/notification deep link targets a today chore — snap to today
        // so the mounted DayPage can consume it (scroll + flash).
        .onChange(of: model.deepLinkChore) { _, target in
            if target != nil { jumpToToday() }
        }
    }

    private func step(_ delta: Int) {
        let target = min(max(index + delta, 0), dates.count - 1)
        guard target != index else { return }
        direction = delta
        withAnimation(.snappy) { index = target }
    }

    private func jumpToToday() {
        guard index != todayIndex else { return }
        direction = todayIndex > index ? 1 : -1
        withAnimation(.snappy) { index = todayIndex }
    }
}
