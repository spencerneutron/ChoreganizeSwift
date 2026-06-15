import Testing
import CoreData
@testable import Choreganize

/// Covers the badge's pure scope-counting core
/// (`NotificationManager.badgeCount(in:household:scopes:from:)`): per-scope partitioning,
/// scope selection, the empty ("no badge") case, counting a scope you're not actively
/// viewing, and that only unfinished chores count. Deterministic via a fixed `now`.
struct BadgeCountTests {

    private func makeContext() -> NSManagedObjectContext {
        CoreDataStack(inMemory: true).newBackgroundContext()
    }

    /// Seeds 2 unfinished Solo dailies + 3 unfinished Household dailies in one context.
    @discardableResult
    private func seed(in ctx: NSManagedObjectContext) -> CDHousehold {
        let household = CDHousehold(context: ctx)
        household.id = UUID()
        household.name = "Home"
        household.createdDate = Date()
        CDChore.make(in: ctx, name: "Dishes", isDaily: true)
        CDChore.make(in: ctx, name: "Trash", isDaily: true)
        CDChore.make(in: ctx, name: "Sweep", isDaily: true, household: household)
        CDChore.make(in: ctx, name: "Laundry", isDaily: true, household: household)
        CDChore.make(in: ctx, name: "Cook", isDaily: true, household: household)
        return household
    }

    private let cal = Calendar.current
    private var now: Date { cal.date(bySettingHour: 9, minute: 0, second: 0, of: Date())! }

    @Test func soloScopeCountsOnlySoloChores() throws {
        let ctx = makeContext()
        try ctx.performAndWait {
            let h = seed(in: ctx)
            try ctx.save()
            let all = try ctx.fetch(NSFetchRequest<CDChore>(entityName: "CDChore"))
            #expect(NotificationManager.badgeCount(in: all, household: h, scopes: [.solo], from: now) == 2)
        }
    }

    @Test func householdScopeCountsOnlyHouseholdChores() throws {
        let ctx = makeContext()
        try ctx.performAndWait {
            let h = seed(in: ctx)
            try ctx.save()
            let all = try ctx.fetch(NSFetchRequest<CDChore>(entityName: "CDChore"))
            #expect(NotificationManager.badgeCount(in: all, household: h, scopes: [.household], from: now) == 3)
        }
    }

    @Test func bothScopesSumAcrossScopes() throws {
        let ctx = makeContext()
        try ctx.performAndWait {
            let h = seed(in: ctx)
            try ctx.save()
            let all = try ctx.fetch(NSFetchRequest<CDChore>(entityName: "CDChore"))
            #expect(NotificationManager.badgeCount(in: all, household: h, scopes: [.solo, .household], from: now) == 5)
        }
    }

    @Test func emptyScopesMeansNoBadge() throws {
        let ctx = makeContext()
        try ctx.performAndWait {
            let h = seed(in: ctx)
            try ctx.save()
            let all = try ctx.fetch(NSFetchRequest<CDChore>(entityName: "CDChore"))
            #expect(NotificationManager.badgeCount(in: all, household: h, scopes: [], from: now) == 0)
        }
    }

    /// Household selected but none resolved (e.g. a Solo-only user): only Solo counts.
    @Test func householdScopeWithoutHouseholdCountsNothingForIt() throws {
        let ctx = makeContext()
        try ctx.performAndWait {
            seed(in: ctx)
            try ctx.save()
            let all = try ctx.fetch(NSFetchRequest<CDChore>(entityName: "CDChore"))
            #expect(NotificationManager.badgeCount(in: all, household: nil, scopes: [.solo, .household], from: now) == 2)
        }
    }

    /// Finishing a chore today drops it from the count — the badge self-clears.
    @Test func completedTodayChoreDropsOutOfCount() throws {
        let ctx = makeContext()
        try ctx.performAndWait {
            let h = seed(in: ctx)
            try ctx.save()
            let all = try ctx.fetch(NSFetchRequest<CDChore>(entityName: "CDChore"))
            let dishes = all.first { $0.household == nil && $0.name == "Dishes" }!
            dishes.recordCompletion(on: now, in: ctx)
            #expect(NotificationManager.badgeCount(in: all, household: h, scopes: [.solo], from: now) == 1)
        }
    }
}
