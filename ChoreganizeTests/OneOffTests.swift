import Testing
import CoreData
import Foundation
@testable import Choreganize

/// CG-27 / #128 — the one-off model: the factory, scope, the 3-at-a-time limit
/// (household-synced vs per-device Personal), the Plus rule for assignees,
/// completing = deleting, and the household cascade.
struct OneOffTests {

    private func makeContext() -> NSManagedObjectContext {
        CoreDataStack(inMemory: true).newBackgroundContext()
    }

    private func household(in ctx: NSManagedObjectContext) -> CDHousehold {
        let household = CDHousehold(context: ctx)
        household.id = UUID()
        household.name = "Home"
        return household
    }

    @Test func makeSetsEveryField() throws {
        let ctx = makeContext()
        try ctx.performAndWait {
            let home = household(in: ctx)
            let date = Date(timeIntervalSinceReferenceDate: 1000)
            let oneOff = CDOneOff.make(in: ctx, title: "Return library books", createdDate: date, household: home)
            try ctx.save()
            #expect(oneOff.id != nil)
            #expect(oneOff.title == "Return library books")
            #expect(oneOff.createdDate == date)
            #expect(oneOff.household === home)
            #expect(oneOff.assignee == nil)
            #expect((home.oneOffs as? Set<CDOneOff>)?.count == 1)
        }
    }

    @Test func scopeSeparatesPersonalFromHousehold() throws {
        let ctx = makeContext()
        ctx.performAndWait {
            let home = household(in: ctx)
            let mine = CDOneOff.make(in: ctx, title: "Call the plumber")
            let shared = CDOneOff.make(in: ctx, title: "Buy lightbulbs", household: home)
            let all = [mine, shared]
            #expect(all.inScope(nil, sharedStore: nil).map(\.title) == ["Call the plumber"])
            #expect(all.inScope(home, sharedStore: nil).map(\.title) == ["Buy lightbulbs"])
        }
    }

    @Test func fetchIsOldestFirst() throws {
        let ctx = makeContext()
        try ctx.performAndWait {
            CDOneOff.make(in: ctx, title: "Second", createdDate: Date(timeIntervalSinceReferenceDate: 20))
            CDOneOff.make(in: ctx, title: "First", createdDate: Date(timeIntervalSinceReferenceDate: 10))
            try ctx.save()
            #expect(try ctx.fetch(oneOffsFetchRequest()).map(\.title) == ["First", "Second"])
        }
    }

    // MARK: Limit

    @Test func limitIsThreeUnlessLifted() {
        #expect(OneOffLimit.canAdd(existing: 0, unlimited: false))
        #expect(OneOffLimit.canAdd(existing: 2, unlimited: false))
        #expect(!OneOffLimit.canAdd(existing: 3, unlimited: false))
        #expect(!OneOffLimit.canAdd(existing: 5, unlimited: false))   // synced in past the limit
        #expect(OneOffLimit.canAdd(existing: 3, unlimited: true))
        #expect(OneOffLimit.canAdd(existing: 40, unlimited: true))
    }

    @Test func householdSettingIsSyncedPersonalIsPerDevice() {
        let ctx = makeContext()
        ctx.performAndWait {
            let home = household(in: ctx)
            #expect(!home.oneOffsUnlimited)   // default: limited
            // The household flag wins in a household, whatever this device's Personal setting.
            #expect(!OneOffLimit.isUnlimited(household: home, personalUnlimited: true))
            home.oneOffsUnlimited = true
            #expect(OneOffLimit.isUnlimited(household: home, personalUnlimited: false))
            // Personal reads the device setting.
            #expect(OneOffLimit.isUnlimited(household: nil, personalUnlimited: true))
            #expect(!OneOffLimit.isUnlimited(household: nil, personalUnlimited: false))
        }
    }

    @Test func collapsesPastTheLimitUntilExpanded() {
        let five = [1, 2, 3, 4, 5]
        #expect(OneOffLimit.collapsed(five, expanded: false).shown == [1, 2, 3])
        #expect(OneOffLimit.collapsed(five, expanded: false).hidden == 2)
        #expect(OneOffLimit.collapsed(five, expanded: true).shown == five)
        #expect(OneOffLimit.collapsed([1, 2, 3], expanded: false).hidden == 0)
    }

    // MARK: Ops

    @Test func addTrimsRefusesBlankAndRespectsTheLimit() throws {
        let ctx = makeContext()
        ctx.performAndWait {
            let added = OneOffOps.add(title: "  Mail the package \n", assignee: nil, household: nil,
                                      existing: 0, unlimited: false, isPlus: false, in: ctx)
            #expect(added?.title == "Mail the package")
            #expect(OneOffOps.add(title: "   ", assignee: nil, household: nil,
                                  existing: 0, unlimited: false, isPlus: false, in: ctx) == nil)
            #expect(OneOffOps.add(title: "Fourth", assignee: nil, household: nil,
                                  existing: 3, unlimited: false, isPlus: false, in: ctx) == nil)
            #expect(OneOffOps.add(title: "Fourth", assignee: nil, household: nil,
                                  existing: 3, unlimited: true, isPlus: false, in: ctx) != nil)
        }
    }

    @Test func assigningNeedsAHouseholdAndPlus() {
        let ctx = makeContext()
        ctx.performAndWait {
            let home = household(in: ctx)
            let free = OneOffOps.add(title: "A", assignee: "_member", household: home,
                                     existing: 0, unlimited: false, isPlus: false, in: ctx)
            #expect(free?.assignee == nil)
            let personal = OneOffOps.add(title: "B", assignee: "_member", household: nil,
                                         existing: 0, unlimited: false, isPlus: true, in: ctx)
            #expect(personal?.assignee == nil)
            let plus = OneOffOps.add(title: "C", assignee: "_member", household: home,
                                     existing: 0, unlimited: false, isPlus: true, in: ctx)
            #expect(plus?.assignee == "_member")

            // Editing follows the same rule; a blank title keeps the old one.
            if let plus {
                OneOffOps.update(plus, title: " ", assignee: nil, isPlus: true, in: ctx)
                #expect(plus.title == "C" && plus.assignee == nil)
                OneOffOps.update(plus, title: "C2", assignee: "_other", isPlus: false, in: ctx)
                #expect(plus.title == "C2" && plus.assignee == nil)
            }
        }
    }

    @Test func completingDeletesAndHouseholdDeletionCascades() throws {
        let ctx = makeContext()
        try ctx.performAndWait {
            let home = household(in: ctx)
            let done = CDOneOff.make(in: ctx, title: "Done", household: home)
            CDOneOff.make(in: ctx, title: "Left", household: home)
            try ctx.save()

            OneOffOps.complete(done, in: ctx)
            #expect(try ctx.fetch(oneOffsFetchRequest()).map(\.title) == ["Left"])

            ctx.delete(home)
            try ctx.save()
            #expect(try ctx.count(for: oneOffsFetchRequest()) == 0)
        }
    }

    /// One-offs never reach stats: the scheduling and completion paths only see chores.
    @Test func oneOffsAreNotChores() throws {
        let ctx = makeContext()
        try ctx.performAndWait {
            CDOneOff.make(in: ctx, title: "Donate old clothes")
            try ctx.save()
            #expect(try ctx.count(for: NSFetchRequest<CDChore>(entityName: "CDChore")) == 0)
            #expect(try ctx.count(for: NSFetchRequest<CDCompletion>(entityName: "CDCompletion")) == 0)
        }
    }
}
