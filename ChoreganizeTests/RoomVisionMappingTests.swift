import Testing
import CoreData
@testable import Choreganize

/// Coverage for mapping the room-vision engine's suggestions into add-flow drafts
/// (Snap a Room, #105): name matching, room resolution, cadence + day spreading,
/// and duplicate detection against a room's existing chores.
struct RoomVisionMappingTests {

    private func makeContext() -> NSManagedObjectContext {
        CoreDataStack(inMemory: true).newBackgroundContext()
    }

    // MARK: Keys

    @Test func choreKeyIgnoresCaseArticlesPunctuationAndPlurals() {
        #expect(RoomVisionMapping.choreKey("Wipe down the counters.") == RoomVisionMapping.choreKey("wipe down counter"))
        #expect(RoomVisionMapping.choreKey("Dust the glass") == "dust glass")          // "ss" isn't a plural
        #expect(RoomVisionMapping.choreKey("Crème brûlée pan") == RoomVisionMapping.choreKey("creme brulee pans"))
        #expect(RoomVisionMapping.choreKey("  ") == "")
    }

    @Test func roomKeyIgnoresSpacingAndPlurals() {
        #expect(RoomVisionMapping.roomKey("Living Room") == RoomVisionMapping.roomKey("livingroom"))
        #expect(RoomVisionMapping.roomKey("living-room") == RoomVisionMapping.roomKey("Living rooms"))
        #expect(RoomVisionMapping.roomKey("Kid's Room") == RoomVisionMapping.roomKey("Kids Room"))
        #expect(RoomVisionMapping.roomKey("Kitchen") != RoomVisionMapping.roomKey("Kitchenette"))
    }

    // MARK: Rooms

    @Test func areaRefMatchesAnExistingRoomOrNamesANewOne() {
        let kitchen = UUID(), living = UUID()
        let areas = [(id: kitchen, name: "Kitchen"), (id: living, name: "Living Room")]
        #expect(RoomVisionMapping.areaRef(forRoomName: "kitchen", among: areas) == .existing(kitchen))
        #expect(RoomVisionMapping.areaRef(forRoomName: "Living room", among: areas) == .existing(living))
        #expect(RoomVisionMapping.areaRef(forRoomName: " Garage ", among: areas) == .new("Garage"))
        #expect(RoomVisionMapping.areaRef(forRoomName: "", among: areas) == .none)
    }

    // MARK: Drafts

    @Test func draftsMapCadenceDropRepeatsAndCapitalize() {
        let room = AreaRef.new("Kitchen")
        let drafts = RoomVisionMapping.drafts(from: [
            SuggestedChore(name: "clean the sink", cadence: .daily),
            SuggestedChore(name: "Wipe down counters", cadence: .weekly),
            SuggestedChore(name: "Clean the sinks", cadence: .weekly),        // repeat of the first
            SuggestedChore(name: "Descale the kettle", cadence: .monthly),
            SuggestedChore(name: "Clean the oven", cadence: .yearly),
            SuggestedChore(name: "   ", cadence: .weekly),                    // blank
        ], areaRef: room, weekdayLoad: [:])

        #expect(drafts.map(\.name) == ["Clean the sink", "Wipe down counters", "Descale the kettle", "Clean the oven"])
        #expect(drafts.allSatisfy { $0.areaRef == room })
        #expect(drafts[0].isDaily && drafts[0].day == nil)
        #expect(!drafts[1].isDaily && drafts[1].frequency == .weekly)
        #expect(drafts[2].frequency == .monthly)
        #expect(drafts[3].frequency == .yearly)
        // Non-daily chores land on distinct days when the week is empty.
        #expect(drafts.dropFirst().map(\.day) == [.monday, .tuesday, .wednesday])
    }

    @Test func spreadDaysFillsTheQuietestDaysFirst() {
        let load: [Weekday: Int] = [.monday: 3, .tuesday: 1, .wednesday: 2, .thursday: 3, .friday: 3, .saturday: 0, .sunday: 3]
        #expect(RoomVisionMapping.spreadDays(count: 4, load: load) == [.saturday, .tuesday, .saturday, .tuesday])
        #expect(RoomVisionMapping.spreadDays(count: 0, load: load).isEmpty)
        #expect(Set(RoomVisionMapping.spreadDays(count: 8, load: [:]).prefix(7)).count == 7)   // a full, even week first
        #expect(RoomVisionMapping.spreadDays(count: 8, load: [:]).last == .monday)
    }

    @Test func duplicatesMatchExistingChoresLoosely() {
        let drafts = RoomVisionMapping.drafts(from: [
            SuggestedChore(name: "Do the dishes", cadence: .daily),
            SuggestedChore(name: "Mop the floor", cadence: .weekly),
        ], areaRef: .none, weekdayLoad: [:])
        let dupes = RoomVisionMapping.duplicates(in: drafts, existingNames: ["do dishes", "Clean the oven"])
        #expect(dupes == [drafts[0].id])
    }

    // MARK: Household context

    @Test func weekdayLoadCountsScheduledChoresOnly() throws {
        let ctx = makeContext()
        ctx.performAndWait {
            CDChore.make(in: ctx, name: "Dishes", isDaily: true, assignedDay: .all)
            CDChore.make(in: ctx, name: "Vacuum", frequency: .weekly, assignedDay: .monday)
            CDChore.make(in: ctx, name: "Mop", frequency: .weekly, assignedDay: .monday)
            let multi = CDChore.make(in: ctx, name: "Trash", frequency: .weekly, assignedDay: .tuesday)
            multi.assignedDaysValue = [.tuesday, .friday]
            CDChore.make(in: ctx, name: "Unassigned", frequency: .monthly)
            let chores = (try? ctx.fetch(NSFetchRequest<CDChore>(entityName: "CDChore"))) ?? []
            #expect(RoomVisionMapping.weekdayLoad(of: chores) == [.monday: 2, .tuesday: 1, .friday: 1])
        }
    }

    @Test func homeContextAndExistingNamesFollowTheRooms() throws {
        let ctx = makeContext()
        ctx.performAndWait {
            let kitchen = CDArea.make(in: ctx, name: "Kitchen")
            CDArea.make(in: ctx, name: "Garage")
            let dishes = CDChore.make(in: ctx, name: "Do the dishes", isDaily: true, assignedDay: .all)
            dishes.area = kitchen
            CDChore.make(in: ctx, name: "Water plants", frequency: .weekly, assignedDay: .monday)
            let areas = (try? ctx.fetch(NSFetchRequest<CDArea>(entityName: "CDArea"))) ?? []
            let chores = (try? ctx.fetch(NSFetchRequest<CDChore>(entityName: "CDChore"))) ?? []

            let home = RoomVisionMapping.homeContext(areas: areas, chores: chores)
            #expect(Set(home.roomNames) == ["Kitchen", "Garage"])
            #expect(home.choresByRoom == ["Kitchen": ["Do the dishes"]])

            #expect(RoomVisionMapping.existingChoreNames(in: .existing(kitchen.id!), chores: chores) == ["Do the dishes"])
            #expect(RoomVisionMapping.existingChoreNames(in: .new("kitchen"), chores: chores) == ["Do the dishes"])
            #expect(RoomVisionMapping.existingChoreNames(in: .new("Attic"), chores: chores).isEmpty)
            #expect(RoomVisionMapping.existingChoreNames(in: .none, chores: chores) == ["Water plants"])
        }
    }

    // MARK: Photo check-off (#107)

    @Test func checkRoomsGroupByRoomWithOtherChoresLast() throws {
        let ctx = makeContext()
        ctx.performAndWait {
            let kitchen = CDArea.make(in: ctx, name: "Kitchen")
            let bath = CDArea.make(in: ctx, name: "Bathroom")
            let wipe = CDChore.make(in: ctx, name: "Wipe counters", isDaily: true, assignedDay: .all)
            wipe.area = kitchen
            let dishes = CDChore.make(in: ctx, name: "Do the dishes", isDaily: true, assignedDay: .all)
            dishes.area = kitchen
            let toilet = CDChore.make(in: ctx, name: "Clean the toilet", frequency: .weekly, assignedDay: .monday)
            toilet.area = bath
            let plants = CDChore.make(in: ctx, name: "Water plants", frequency: .weekly, assignedDay: .monday)

            let rooms = RoomVisionMapping.checkRooms(for: [wipe, plants, toilet, dishes])
            #expect(rooms.map(\.title) == ["Bathroom", "Kitchen", "Other chores"])
            #expect(rooms[1].chores.map { $0.name ?? "" } == ["Do the dishes", "Wipe counters"])   // A→Z
            #expect(rooms[1].areaID == kitchen.id)
            #expect(rooms[2].areaID == nil && rooms[2].chores == [plants])
            #expect(RoomVisionMapping.checkRooms(for: []).isEmpty)
        }
    }

    @Test func checkRoomsCapTheChoresPerRoom() throws {
        let ctx = makeContext()
        ctx.performAndWait {
            let chores = (1...40).map { CDChore.make(in: ctx, name: "Chore \($0)", isDaily: true, assignedDay: .all) }
            let rooms = RoomVisionMapping.checkRooms(for: chores)
            #expect(rooms.count == 1)
            #expect(rooms[0].chores.count == RoomVisionMapping.maxCheckChores)
            #expect(rooms[0].chores.first?.name == "Chore 1")       // numeric-aware ordering
        }
    }

    @Test func onlyLooksDoneIsPreselected() {
        #expect(RoomVisionMapping.preselected([1, 2, 3, 4], verdicts: [.looksDone, .cantTell, .notDone, .looksDone]) == [1, 4])
        #expect(RoomVisionMapping.preselected([1, 2], verdicts: [.cantTell]).isEmpty)          // missing verdicts never select
        #expect(RoomVisionMapping.preselected([Int](), verdicts: [.looksDone]).isEmpty)
    }
}
