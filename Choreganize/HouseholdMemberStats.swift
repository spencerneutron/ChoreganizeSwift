import SwiftUI
import CoreData
import CloudKit

/// CG-28 / #129 — who's been helping: each household member's chores in the last 30 days
/// and their run of days, in Hub ▸ Household (Settings ▸ General on the Mac). Plus, like
/// Insights. Meant to encourage, not keep score: only members who did something appear,
/// you first and then by name, with no ranks or shares.
enum HouseholdMembers {
    /// One row: a member, or everyone the household can't name folded together.
    struct Row: Identifiable, Equatable {
        var id: String
        var name: String
        var choresDone: Int
        /// Nil for the folded row, whose runs don't add up.
        var streak: Int?
    }

    /// A summary and the household it's for, so a slow load never shows under another.
    struct Loaded: Equatable {
        var householdID: NSManagedObjectID
        var summary: InsightsMath.MembersSummary
    }

    /// What to show for `householdID`: nothing while it loads, or for a household only you use.
    static func shown(_ loaded: Loaded?, for householdID: NSManagedObjectID?,
                      participantIDs: some Collection<String>) -> InsightsMath.MembersSummary? {
        guard let loaded, let householdID, loaded.householdID == householdID,
              isShared(loaded.summary, participantIDs: participantIDs) else { return nil }
        return loaded.summary
    }

    /// The household's completions over the last `memberHistoryDays`, summarised off the
    /// main thread.
    static func summary(for householdID: NSManagedObjectID, stack: CoreDataStack = .shared,
                        today: Date = Date()) async -> InsightsMath.MembersSummary? {
        let cal = Calendar.current
        guard let since = cal.date(byAdding: .day, value: -(InsightsMath.memberHistoryDays - 1),
                                   to: cal.startOfDay(for: today)) else { return nil }
        let ctx = stack.newBackgroundContext()
        let completions = await ctx.perform {
            let request = NSFetchRequest<CDCompletion>(entityName: "CDCompletion")
            request.predicate = NSPredicate(format: "household == %@ AND date >= %@", householdID, since as NSDate)
            request.relationshipKeyPathsForPrefetching = ["chore"]
            return ((try? ctx.fetch(request)) ?? []).compactMap { c -> InsightsMath.MemberCompletion? in
                guard let date = c.date else { return nil }
                return .init(choreID: c.chore?.id, completedBy: c.completedBy, date: date)
            }
        }
        return InsightsMath.membersSummary(completions, today: today, calendar: cal)
    }

    /// Whether there's more than one person to show: the share's participants, or
    /// whoever did the household's chores lately. A household only you use shows nothing.
    static func isShared(_ summary: InsightsMath.MembersSummary, participantIDs: some Collection<String>) -> Bool {
        // CloudKit's placeholder for "you" isn't another person (it stands in for your own
        // id until that's known).
        Set(participantIDs).union(summary.members.map(\.id))
            .subtracting([CKCurrentUserDefaultName])
            .count >= 2
    }

    /// The rows in display order: you, then members by name, then anyone the household
    /// can't name (someone who left, or names that haven't loaded yet) as one row.
    static func rows(_ summary: InsightsMath.MembersSummary, names: [String: String], me: String?) -> [Row] {
        var mine: Row?
        var named: [Row] = []
        var unknown: [InsightsMath.MemberStats] = []
        for member in summary.members {
            if member.id == me {
                mine = Row(id: member.id, name: "You", choresDone: member.choresDone, streak: member.streak)
            } else if let name = names[member.id] {
                named.append(Row(id: member.id, name: name, choresDone: member.choresDone, streak: member.streak))
            } else {
                unknown.append(member)
            }
        }
        named.sort {
            let order = $0.name.localizedStandardCompare($1.name)
            return order == .orderedSame ? $0.id < $1.id : order == .orderedAscending
        }
        var rows = (mine.map { [$0] } ?? []) + named
        if unknown.count == 1, let only = unknown.first {
            rows.append(Row(id: only.id, name: "A household member", choresDone: only.choresDone, streak: only.streak))
        } else if unknown.count > 1 {
            rows.append(Row(id: "others", name: "Other members",
                            choresDone: unknown.reduce(0) { $0 + $1.choresDone }, streak: nil))
        }
        return rows
    }

    static func choresText(_ count: Int) -> String {
        count == 1 ? "1 chore" : "\(count) chores"
    }

    static func daysText(_ count: Int) -> String {
        count == 1 ? "1 day" : "\(count) days"
    }
}

/// The member rows, for the household's section. Without Plus, one locked row.
struct HouseholdMemberRows: View {
    var summary: InsightsMath.MembersSummary
    var isPlus: Bool
    @ObservedObject private var directory = CompleterDirectory.shared

    var body: some View {
        if isPlus {
            let rows = HouseholdMembers.rows(summary, names: directory.namesByID, me: CompleterIdentity.cachedID)
            ForEach(rows) { row in
                LabeledContent {
                    // A run worth mentioning: two days or more.
                    if let streak = row.streak, streak >= 2 {
                        HStack(spacing: 4) {
                            Image(systemName: "flame.fill")
                                .foregroundStyle(.orange)
                            Text(HouseholdMembers.daysText(streak))
                        }
                    }
                } label: {
                    Text(row.name)
                    Text(HouseholdMembers.choresText(row.choresDone))
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(row.name)
                .accessibilityValue(accessibilityValue(row))
            }
        } else {
            LockedValueRow(label: "Who's been helping", value: "Plus")
        }
    }

    private func accessibilityValue(_ row: HouseholdMembers.Row) -> String {
        let chores = "\(HouseholdMembers.choresText(row.choresDone)) in the last \(summary.windowDays) days"
        guard let streak = row.streak, streak >= 2 else { return chores }
        return "\(chores), \(HouseholdMembers.daysText(streak)) in a row"
    }
}

/// The footer under the member rows.
struct HouseholdMemberFooter: View {
    var summary: InsightsMath.MembersSummary
    var isPlus: Bool

    var body: some View {
        if !isPlus {
            Text("Seeing who's been helping requires Choreganize Plus (\(PlatformText.plusLocation)).")
        } else if summary.total == 0 {
            Text("No chores done in the last \(summary.windowDays) days yet.")
        } else {
            let together = "Together, \(HouseholdMembers.choresText(summary.total)) in the last \(summary.windowDays) days."
            if summary.members.contains(where: { $0.streak >= 2 }) {
                Text("\(together) \(Image(systemName: "flame.fill")) counts days in a row with at least one.")
                    .accessibilityLabel("\(together) The flame counts days in a row with at least one.")
            } else {
                Text(together)
            }
        }
    }
}

extension View {
    /// Loads the household's member stats into `loaded` and keeps them current while the
    /// view is up: when the household changes, after saves (synced completions included),
    /// and when the day turns over.
    func loadsHouseholdMembers(for householdID: NSManagedObjectID?,
                               into loaded: Binding<HouseholdMembers.Loaded?>) -> some View {
        modifier(HouseholdMembersLoader(householdID: householdID, loaded: loaded))
    }
}

private struct HouseholdMembersLoader: ViewModifier {
    var householdID: NSManagedObjectID?
    @Binding var loaded: HouseholdMembers.Loaded?
    @State private var reloads = 0

    private struct Key: Equatable {
        var householdID: NSManagedObjectID?
        var reloads: Int
    }

    func body(content: Content) -> some View {
        content
            .task(id: Key(householdID: householdID, reloads: reloads)) {
                guard let householdID else { loaded = nil; return }
                // A burst of saves (a sync import) loads once: each one cancels the wait.
                if loaded?.householdID == householdID {
                    guard (try? await Task.sleep(for: .milliseconds(500))) != nil else { return }
                }
                let summary = await HouseholdMembers.summary(for: householdID)
                guard !Task.isCancelled, let summary else { return }
                loaded = .init(householdID: householdID, summary: summary)
            }
            .onReceive(NotificationCenter.default.publisher(for: NSManagedObjectContext.didSaveObjectsNotification)
                .receive(on: RunLoop.main)) { _ in reloads += 1 }
            .onReceive(NotificationCenter.default.publisher(for: .NSCalendarDayChanged)
                .receive(on: RunLoop.main)) { _ in reloads += 1 }
    }
}
