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
        let stats = InsightsMath.choreStats(for: chore)
        Section {
            LabeledContent("Last done", value: Self.lastDoneText(stats.lastDone))
            if let gap = stats.typicalGapDays {
                LabeledContent("Usually done", value: Self.gapText(gap))
            }
            if plusUnlocked {
                LabeledContent("On time", value: Self.onTimeText(stats.onTime))
                if isHousehold, let top = stats.topCompleter {
                    LabeledContent("Usually done by", value: completerText(top))
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
                Text("On time counts the days it was due in the last \(Self.windowText(stats.onTimeWindowDays)) that it was done that day.")
            } else {
                Text("How often it's done on time\(isHousehold ? " and who usually does it" : "") requires Choreganize Plus (\(PlatformText.plusLocation)).")
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

    static func gapText(_ days: Int) -> String {
        switch days {
        case ...1: return "Every day"
        case 7: return "Every week"
        case let d where d % 7 == 0 && d <= 28: return "Every \(d / 7) weeks"
        default: return "Every \(days) days"
        }
    }

    static func onTimeText(_ stats: InsightsMath.WindowStats) -> String {
        guard stats.due > 0 else { return "Not due yet" }
        return "\(stats.completed) of \(stats.due) · \(stats.percent)%"
    }

    static func windowText(_ days: Int) -> String {
        switch days {
        case 30: return "30 days"
        case 180: return "6 months"
        case 730: return "2 years"
        default: return "\(days) days"
        }
    }

    private func completerText(_ top: InsightsMath.ChoreStats.Completer) -> String {
        let name = top.id == CompleterIdentity.cachedID ? "You" : (completers.namesByID[top.id] ?? "A household member")
        return "\(name) · \(top.count) of \(top.attributed)"
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
        Section {
            if plusUnlocked {
                let stats = InsightsMath.roomStats(chores: chores)
                LabeledContent("On time", value: ChoreStatsSection.onTimeText(stats.onTime))
                if let worst = stats.mostMissed {
                    LabeledContent("Most missed", value: "\(worst.name) · \(worst.missed) of \(worst.due)")
                }
            } else {
                LockedValueRow(label: "On time", value: "Plus")
                LockedValueRow(label: "Most missed", value: "Plus")
            }
        } header: {
            Text("Stats")
        } footer: {
            if plusUnlocked {
                Text("On time counts the days its chores were due in the last 30 days that they were done that day.")
            } else {
                Text("Room stats require Choreganize Plus (\(PlatformText.plusLocation)).")
            }
        }
    }
}
