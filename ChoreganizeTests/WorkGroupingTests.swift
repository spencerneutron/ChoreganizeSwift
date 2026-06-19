import Testing
import CoreData
@testable import Choreganize

/// Coverage for the pure Work-view grouping logic (#60): deterministic ordering,
/// empty-group dropping, and the "No Room" / "Every Day" buckets.
struct WorkGroupingTests {

    private func makeContext() -> NSManagedObjectContext {
        CoreDataStack(inMemory: true).newBackgroundContext()
    }

    @Test func noneReturnsOneImplicitGroupOrEmpty() throws {
        let ctx = makeContext()
        ctx.performAndWait {
            #expect(WorkGrouping.none.sections(for: []).isEmpty)
            let daily = CDChore.make(in: ctx, name: "Dishes", isDaily: true)
            let groups = WorkGrouping.none.sections(for: [daily])
            #expect(groups.count == 1)
            #expect(groups[0].title == "")
            #expect(groups[0].chores.count == 1)
        }
    }

    @Test func frequencyOrdersEveryDayThenWeeklyMonthlyYearly() throws {
        let ctx = makeContext()
        ctx.performAndWait {
            let daily   = CDChore.make(in: ctx, name: "Make bed", isDaily: true)
            let weekly  = CDChore.make(in: ctx, name: "Vacuum", isDaily: false, frequency: .weekly, assignedDay: .monday)
            let monthly = CDChore.make(in: ctx, name: "Filters", isDaily: false, frequency: .monthly, assignedDay: .monday)
            let yearly  = CDChore.make(in: ctx, name: "Gutters", isDaily: false, frequency: .yearly, assignedDay: .monday)

            // Pass in a deliberately jumbled order — output order must be fixed.
            let groups = WorkGrouping.frequency.sections(for: [yearly, weekly, daily, monthly])
            #expect(groups.map(\.title) == ["Every Day", "Weekly", "Monthly", "Yearly"])
            #expect(groups[0].chores.first === daily)
        }
    }

    @Test func frequencyDropsEmptyGroups() throws {
        let ctx = makeContext()
        ctx.performAndWait {
            let weekly = CDChore.make(in: ctx, name: "Vacuum", isDaily: false, frequency: .weekly, assignedDay: .monday)
            let groups = WorkGrouping.frequency.sections(for: [weekly])
            #expect(groups.map(\.title) == ["Weekly"])   // no empty Every Day/Monthly/Yearly
        }
    }

    @Test func roomGroupsAlphabeticallyWithNoRoomLast() throws {
        let ctx = makeContext()
        ctx.performAndWait {
            let kitchen = CDArea.make(in: ctx, name: "Kitchen")
            let bath    = CDArea.make(in: ctx, name: "Bathroom")
            let dishes  = CDChore.make(in: ctx, name: "Dishes", isDaily: true);  dishes.area = kitchen
            let scrub   = CDChore.make(in: ctx, name: "Scrub", isDaily: true);   scrub.area = bath
            let orphan  = CDChore.make(in: ctx, name: "Orphan", isDaily: true)   // no area

            let groups = WorkGrouping.room.sections(for: [dishes, scrub, orphan])
            #expect(groups.map(\.title) == ["Bathroom", "Kitchen", "No Room"])
            #expect(groups.last?.chores.first === orphan)
        }
    }

    @Test func roomWithNoAreasIsSingleNoRoomGroup() throws {
        let ctx = makeContext()
        ctx.performAndWait {
            let a = CDChore.make(in: ctx, name: "A", isDaily: true)
            let b = CDChore.make(in: ctx, name: "B", isDaily: true)
            let groups = WorkGrouping.room.sections(for: [a, b])
            #expect(groups.map(\.title) == ["No Room"])
            #expect(groups[0].chores.count == 2)
        }
    }
}
