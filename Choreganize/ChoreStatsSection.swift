import SwiftUI

/// CG-28 / #129 — a chore's own stats, in its editor: when it was last done and how often
/// it usually is (free), and how often it's done on its due day and who usually does it
/// (Plus, like the Insights tab).
struct ChoreStatsSection: View {
    @ObservedObject var chore: CDChore
    @ObservedObject private var entitlements = EntitlementStore.shared
    @ObservedObject private var completers = CompleterDirectory.shared

    private var plusUnlocked: Bool { Entitlements.isPlus(for: chore.household) }
    private var isHousehold: Bool { chore.household != nil }

    var body: some View {
        let stats = InsightsMath.choreStats(for: chore, includesOnTime: plusUnlocked)
        Section {
            LabeledContent("Last done", value: Self.lastDoneText(stats.lastDone))
            if let gap = stats.typicalGapDays {
                LabeledContent("Usually done", value: Self.gapText(gap))
            }
            if plusUnlocked {
                if InsightsMath.hasDueDays(chore) {
                    LabeledContent("On time", value: Self.onTimeText(stats.onTime))
                        .accessibilityValue(Self.onTimeAccessibilityText(stats.onTime))
                } else {
                    LabeledContent("On time", value: "No set day")
                }
                if isHousehold, let top = stats.topCompleter {
                    LabeledContent("Usually done by", value: completerText(top))
                        .accessibilityValue("\(completerName(top)), \(top.count) of \(top.attributed) completions")
                }
            } else {
                LockedValueRow(label: "On time", value: "Plus")
                if isHousehold {
                    LockedValueRow(label: "Usually done by", value: "Plus")
                }
            }
        } header: {
            Text("Stats")
        } footer: {
            if plusUnlocked {
                Text("On time: how many of its due days in the last \(Self.windowText(stats.onTimeWindowDays)) it was done on the day.")
            } else if isHousehold {
                Text("How often it's done on time and who usually does it require Choreganize Plus (\(PlatformText.plusLocation)).")
            } else {
                Text("How often it's done on time requires Choreganize Plus (\(PlatformText.plusLocation)).")
            }
        }
    }

    static func lastDoneText(_ date: Date?, today: Date = Date(), calendar cal: Calendar = .current) -> String {
        guard let date else { return "Never" }
        if cal.isDate(date, inSameDayAs: today) { return "Today" }
        if let yesterday = cal.date(byAdding: .day, value: -1, to: today), cal.isDate(date, inSameDayAs: yesterday) {
            return "Yesterday"
        }
        let sameYear = cal.component(.year, from: date) == cal.component(.year, from: today)
        return date.formatted(sameYear ? .dateTime.month(.abbreviated).day() : .dateTime.month(.abbreviated).day().year())
    }

    /// A gap in days, in the schedule's own words where it's close: weeks when it's an exact
    /// number of them, months and years when it's within a few days of one.
    static func gapText(_ days: Int) -> String {
        if days <= 1 { return "Every day" }
        if days % 7 == 0 && days <= 56 { return days == 7 ? "Every week" : "Every \(days / 7) weeks" }
        let years = (Double(days) / 365.25).rounded()
        if years >= 1, abs(Double(days) - years * 365.25) <= 10 {
            return years == 1 ? "Every year" : "Every \(Int(years)) years"
        }
        let months = (Double(days) / 30.44).rounded()
        if months >= 1, months < 12, abs(Double(days) - months * 30.44) <= 3 {
            return months == 1 ? "Every month" : "Every \(Int(months)) months"
        }
        return "Every \(days) days"
    }

    static func onTimeText(_ stats: InsightsMath.WindowStats) -> String {
        guard stats.due > 0 else { return "No due days yet" }
        return "\(stats.completed) of \(stats.due) · \(stats.percent)%"
    }

    static func onTimeAccessibilityText(_ stats: InsightsMath.WindowStats) -> String {
        guard stats.due > 0 else { return "No due days yet" }
        return "\(stats.completed) of \(stats.due) due days done, \(stats.percent) percent"
    }

    static func windowText(_ days: Int) -> String {
        let years = (Double(days) / 365).rounded()
        if years >= 1, abs(Double(days) - years * 365) <= 15 {
            return years == 1 ? "year" : "\(Int(years)) years"
        }
        if days > 30 && days % 30 == 0 { return "\(days / 30) months" }
        return "\(days) days"
    }

    private func completerName(_ top: InsightsMath.ChoreStats.Completer) -> String {
        top.id == CompleterIdentity.cachedID ? "You" : (completers.namesByID[top.id] ?? "A household member")
    }

    private func completerText(_ top: InsightsMath.ChoreStats.Completer) -> String {
        "\(completerName(top)) · \(top.count) of \(top.attributed)"
    }
}

/// CG-28 / #129 — a room's stats, in its editor: how often its chores are done on their
/// due days, and which one misses most. Plus, like the Insights tab's room breakdown.
struct AreaStatsSection: View {
    /// The room's chores, as saved.
    var chores: [CDChore]
    var household: CDHousehold?
    @ObservedObject private var entitlements = EntitlementStore.shared

    private var plusUnlocked: Bool { Entitlements.isPlus(for: household) }

    var body: some View {
        if !chores.isEmpty {
            Section {
                if plusUnlocked {
                    let stats = InsightsMath.roomStats(chores: chores)
                    LabeledContent("On time", value: ChoreStatsSection.onTimeText(stats.onTime))
                        .accessibilityValue(ChoreStatsSection.onTimeAccessibilityText(stats.onTime))
                    if let worst = stats.mostMissed {
                        LabeledContent("Most missed", value: "\(worst.name) · missed \(worst.missed) of \(worst.due)")
                            .accessibilityValue("\(worst.name), missed \(worst.missed) of \(worst.due) due days")
                    }
                } else {
                    LockedValueRow(label: "On time", value: "Plus")
                    LockedValueRow(label: "Most missed", value: "Plus")
                }
            } header: {
                Text("Stats")
            } footer: {
                if plusUnlocked {
                    Text("On time: how many of its chores' due days in the last 30 days were done on the day.")
                } else {
                    Text("Room stats require Choreganize Plus (\(PlatformText.plusLocation)).")
                }
            }
        }
    }
}
