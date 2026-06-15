import Testing
import CoreData
@testable import Choreganize

/// P0 coverage for the add-flow commit engine: drafts → CDChore/CDArea via the shared
/// factories, with new-area dedup, existing-area reuse, and scope correctness.
struct AddFlowCommitTests {

    private func makeContext() -> NSManagedObjectContext {
        CoreDataStack(inMemory: true).newBackgroundContext()
    }

    @Test func commitTranslatesScheduleFields() throws {
        let ctx = makeContext()
        try ctx.performAndWait {
            let made = AddFlowCommit.commit([
                ChoreDraft(name: "Dishes", isDaily: true),
                ChoreDraft(name: "Mop", isDaily: false, frequency: .monthly, day: .friday)
            ], in: ctx, household: nil)

            #expect(made.count == 2)
            let dishes = try #require(made.first { $0.name == "Dishes" })
            #expect(dishes.isDaily)
            #expect(dishes.frequencyValue == nil)
            #expect(dishes.assignedDayValue == .all)

            let mop = try #require(made.first { $0.name == "Mop" })
            #expect(!mop.isDaily)
            #expect(mop.frequencyValue == .monthly)
            #expect(mop.assignedDayValue == .friday)
        }
    }

    @Test func commitTrimsNamesAndSkipsBlankAreaRef() throws {
        let ctx = makeContext()
        try ctx.performAndWait {
            let made = AddFlowCommit.commit([
                ChoreDraft(name: "  Vacuum  ", isDaily: true, areaRef: .new("   "))
            ], in: ctx, household: nil)
            let chore = try #require(made.first)
            #expect(chore.name == "Vacuum")
            #expect(chore.area == nil)   // whitespace-only new-area name ⇒ no area
        }
    }

    @Test func commitDedupesNewAreasByName() throws {
        let ctx = makeContext()
        try ctx.performAndWait {
            let made = AddFlowCommit.commit([
                ChoreDraft(name: "Dishes", isDaily: true, areaRef: .new("Kitchen")),
                ChoreDraft(name: "Counters", isDaily: true, areaRef: .new("kitchen "))
            ], in: ctx, household: nil)

            let areas = try ctx.fetch(NSFetchRequest<CDArea>(entityName: "CDArea"))
            #expect(areas.count == 1)                // one Kitchen, not two
            #expect(made[0].area === made[1].area)    // both chores share it
            #expect(made[0].area?.name == "Kitchen")
        }
    }

    @Test func commitReusesExistingAreaByName() throws {
        let ctx = makeContext()
        try ctx.performAndWait {
            let kitchen = CDArea.make(in: ctx, name: "Kitchen")
            try ctx.save()

            let made = AddFlowCommit.commit([
                ChoreDraft(name: "Dishes", isDaily: true, areaRef: .new("KITCHEN"))
            ], in: ctx, household: nil)

            let areas = try ctx.fetch(NSFetchRequest<CDArea>(entityName: "CDArea"))
            #expect(areas.count == 1)             // reused, no duplicate
            #expect(made[0].area === kitchen)
        }
    }

    @Test func commitResolvesExistingAreaById() throws {
        let ctx = makeContext()
        try ctx.performAndWait {
            let bath = CDArea.make(in: ctx, name: "Bathroom")
            try ctx.save()
            let id = try #require(bath.id)

            let made = AddFlowCommit.commit([
                ChoreDraft(name: "Scrub", isDaily: true, areaRef: .existing(id))
            ], in: ctx, household: nil)
            #expect(made[0].area === bath)
        }
    }

    @Test func commitKeepsAreaReuseWithinScope() throws {
        let ctx = makeContext()
        try ctx.performAndWait {
            // A "Kitchen" exists in a Household scope.
            let house = CDHousehold(context: ctx)
            house.id = UUID(); house.name = "H"; house.createdDate = Date()
            CDArea.make(in: ctx, name: "Kitchen", household: house)
            try ctx.save()

            // A Solo (nil) draft for "Kitchen" must NOT reuse the household's area.
            let made = AddFlowCommit.commit([
                ChoreDraft(name: "Dishes", isDaily: true, areaRef: .new("Kitchen"))
            ], in: ctx, household: nil)

            #expect(made[0].household == nil)              // chore is solo
            #expect(made[0].area?.household == nil)        // and so is its area
            let kitchens = try ctx.fetch(NSFetchRequest<CDArea>(entityName: "CDArea"))
                .filter { $0.name == "Kitchen" }
            #expect(kitchens.count == 2)                   // one per scope
        }
    }

    @Test func commitOnEmptyDraftsIsNoop() throws {
        let ctx = makeContext()
        try ctx.performAndWait {
            let made = AddFlowCommit.commit([], in: ctx, household: nil)
            #expect(made.isEmpty)
            let chores = try ctx.fetch(NSFetchRequest<CDChore>(entityName: "CDChore"))
            #expect(chores.isEmpty)
        }
    }
}

@MainActor
struct AddFlowModelTests {

    @Test func addRemoveTracksDraftCount() {
        let model = AddFlowModel(grouping: .byArea)
        #expect(model.draftCount == 0)
        let a = ChoreDraft(name: "A", isDaily: true)
        model.add(a)
        model.add(ChoreDraft(name: "B", isDaily: true))
        #expect(model.draftCount == 2)
        model.remove(a.id)
        #expect(model.draftCount == 1)
    }

    @Test func commitWritesAndClearsDrafts() throws {
        let ctx = CoreDataStack(inMemory: true).viewContext
        try ctx.setQueryGenerationFrom(nil)   // in-memory store can't pin to a query generation
        let model = AddFlowModel(grouping: .byDay)
        model.add(ChoreDraft(name: "Trash", isDaily: false, frequency: .weekly, day: .monday))
        let made = model.commit(in: ctx, household: nil)
        #expect(made.count == 1)
        #expect(model.draftCount == 0)            // drafts cleared after commit
        #expect(made[0].assignedDayValue == .monday)
    }

    @Test func addToActiveGroupPinsAreaInRoomLens() {
        let model = AddFlowModel(grouping: .byArea)
        model.startGroup(.area(.new("Kitchen")))
        model.addToActiveGroup(name: "Dishes", isDaily: true)
        model.addToActiveGroup(name: "Mop", isDaily: false, frequency: .weekly, day: .monday)
        #expect(model.drafts.allSatisfy { $0.areaRef == .new("Kitchen") })   // area pinned
        #expect(model.drafts[0].isDaily)                                     // per-chore schedule kept
        #expect(model.drafts[1].day == .monday)
        #expect(model.count(in: .area(.new("Kitchen"))) == 2)
    }

    @Test func addToActiveGroupPinsDayInDayLens() {
        let model = AddFlowModel(grouping: .byDay)
        model.startGroup(.day(.tuesday))
        model.addToActiveGroup(name: "Trash", areaRef: .new("Garage"))
        #expect(model.drafts[0].day == .tuesday)        // day pinned
        #expect(model.drafts[0].isDaily == false)
        #expect(model.drafts[0].areaRef == .new("Garage"))   // per-chore area kept
        #expect(model.count(in: .day(.tuesday)) == 1)
    }

    @Test func everyDayGroupMakesDailyDrafts() {
        let model = AddFlowModel(grouping: .byDay)
        model.startGroup(.day(.all))
        model.addToActiveGroup(name: "Make bed")
        #expect(model.drafts[0].isDaily)
        #expect(model.drafts[0].day == nil)
        #expect(model.count(in: .day(.all)) == 1)
    }

    @Test func addToActiveGroupNoopWithoutActiveGroup() {
        let model = AddFlowModel(grouping: .byArea)
        model.addToActiveGroup(name: "Orphan")
        #expect(model.draftCount == 0)
    }
}
