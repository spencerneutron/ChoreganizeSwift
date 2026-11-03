import CoreData
import Foundation

// CG-27 / #128 — one-offs: genuine one-time tasks that live at the top of the
// Work view until they're checked off. They have no frequency, day or reminders
// and are never counted: every stats path (Insights, streaks, the calendar,
// widgets, the badge, reminders, member notifications, Siri, backups) reads only
// CDChore / CDCompletion, so one-offs are excluded by construction. Completing
// one deletes it; nothing is kept.
//
// A separate entity rather than a flag on CDChore: an older App Store client in a
// shared household would show a flagged chore as an ordinary chore and count it,
// but it ignores an unknown CloudKit record type.

/// The one-offs a scope's Work view shows, oldest first.
func oneOffsFetchRequest() -> NSFetchRequest<CDOneOff> {
    let request = NSFetchRequest<CDOneOff>(entityName: "CDOneOff")
    request.sortDescriptors = [NSSortDescriptor(key: "createdDate", ascending: true)]
    request.relationshipKeyPathsForPrefetching = ["household"]
    return request
}

/// The "3 at a time" rule. It gates adding only: whatever syncs in is always shown.
enum OneOffLimit {
    static let count = 3

    static let refusal = "One-offs are for a few things at a time. Finish one to add another."

    /// Whether a scope's limit is lifted. A household's setting is synced for every
    /// member (`CDHousehold.oneOffsUnlimited`); Personal has no household record, so
    /// its setting is per device.
    static func isUnlimited(household: CDHousehold?, personalUnlimited: Bool) -> Bool {
        household.map(\.oneOffsUnlimited) ?? personalUnlimited
    }

    static func canAdd(existing: Int, unlimited: Bool) -> Bool {
        unlimited || existing < count
    }

    /// Past the limit the list shows `count` rows and a "Show all (N)" row.
    static func collapsed<T>(_ items: [T], expanded: Bool) -> (shown: [T], hidden: Int) {
        guard !expanded, items.count > count else { return (items, 0) }
        return (Array(items.prefix(count)), items.count - count)
    }
}

enum OneOffOps {
    /// Adds a one-off, or returns nil for a blank title or a scope at its limit.
    /// `assignee` is kept only in a household with Plus (assigning is Plus, the
    /// same rule as chores).
    @discardableResult
    static func add(title: String, assignee: String?, household: CDHousehold?,
                    existing: Int, unlimited: Bool, isPlus: Bool,
                    now: Date = Date(), in context: NSManagedObjectContext) -> CDOneOff? {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, OneOffLimit.canAdd(existing: existing, unlimited: unlimited) else { return nil }
        let oneOff = CDOneOff.make(in: context, title: trimmed, createdDate: now, household: household)
        oneOff.assignee = household != nil && isPlus ? assignee : nil
        try? context.save()
        return oneOff
    }

    /// Edits the title and, in a household with Plus, the assignee. A blank title
    /// keeps the old one.
    static func update(_ oneOff: CDOneOff, title: String, assignee: String?, isPlus: Bool,
                       in context: NSManagedObjectContext) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { oneOff.title = trimmed }
        if oneOff.household != nil && isPlus { oneOff.assignee = assignee }
        try? context.save()
    }

    /// Checking a one-off off removes it. (Delete from the context menu is the same
    /// operation without the poof.)
    static func complete(_ oneOff: CDOneOff, in context: NSManagedObjectContext) {
        context.delete(oneOff)
        try? context.save()
    }
}

extension CDOneOff {
    /// Whether the one-off is assigned to the signed-in member (the same identity
    /// domain as `CDChore.assignee`).
    var isAssignedToCurrentUser: Bool {
        guard let assignee else { return false }
        return assignee == CompleterIdentity.cachedID
    }
}
