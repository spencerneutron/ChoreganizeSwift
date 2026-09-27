import Testing
import CoreData
import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif
@testable import Choreganize

/// Coverage for Describe Chores (#106) without the model: reading schedule words,
/// the grounding that keeps invented chores / rooms out, prompt building, the mapping
/// onto drafts (with and without Plus), duplicates, and commits of Plus schedules.
/// Prompt *quality* is measured by tools/fm-eval (`--only describe`), not here.
struct DescribeChoresTests {

    // MARK: Schedule words

    @Test(arguments: [
        ("every other Saturday", ChoreCadence.weekly, ["saturday"], 2),
        ("every night", .daily, [], 1),
        ("every Monday night", .weekly, ["monday"], 1),
        ("Mon & Thu", .weekly, ["monday", "thursday"], 1),
        ("on weekends", .weekly, ["sunday", "saturday"], 1),
        ("every weekday", .weekly, ["monday", "tuesday", "wednesday", "thursday", "friday"], 1),
        ("twice a week", .weekly, [], 1),
        ("once a month", .monthly, [], 1),
        ("the first Sunday of every month", .monthly, ["sunday"], 1),
        ("every three months", .monthly, [], 3),
        ("every 6 months", .monthly, [], 6),
        ("every couple of weeks", .weekly, [], 2),
        ("biweekly", .weekly, [], 2),
        ("every fortnight", .weekly, [], 2),
        ("quarterly", .monthly, [], 3),
        ("twice a year", .monthly, [], 6),
        ("twice a month", .weekly, [], 2),
        ("every spring", .yearly, [], 1),
        ("Every January", .yearly, [], 1),
        ("daily in summer", .daily, [], 1),
        ("every other day", .daily, [], 1),
        ("Thursday evenings", .weekly, ["thursday"], 1),
    ] as [(String, ChoreCadence, [String], Int)])
    func scheduleWordsRead(_ phrase: String, cadence: ChoreCadence, days: [String], every: Int) {
        let reading = ScheduleWords.read(phrase)
        #expect(reading.cadence == cadence)
        #expect(Set(reading.days) == Set(days))
        #expect(reading.every == every)
    }

    @Test func scheduleWordsLeaveUnknownPhrasesToTheModel() {
        #expect(ScheduleWords.read("").cadence == nil)
        #expect(ScheduleWords.read("after every use").cadence == nil)
        #expect(ScheduleWords.read("when it's full") == .init())
    }

    @Test func weekdaysComeBackSundayFirst() {
        #expect(ScheduleWords.read("Fridays and Mondays").days == ["monday", "friday"])
    }

    // MARK: Grounding

    @Test func choresMustComeFromTheText() {
        #expect(DescribeChoresGrounding.isGrounded(name: "Do the dishes", in: "Dishes daily"))
        #expect(DescribeChoresGrounding.isGrounded(name: "Vacuum the rug", in: "vacum the rug evry sunday"))
        #expect(DescribeChoresGrounding.isGrounded(name: "vacuum", in: "vacum evry sunday"))   // one typo apart
        #expect(!DescribeChoresGrounding.isGrounded(name: "Clean the kitchen", in: "Hello there!"))
        #expect(!DescribeChoresGrounding.isGrounded(name: "Do the chores", in: "I hate doing chores"))   // generic words only
    }

    @Test func whenWordsMustComeFromTheText() {
        #expect(DescribeChoresGrounding.groundedWhen("every Sunday", in: "vacum the rug evry sunday") == "every Sunday")
        #expect(DescribeChoresGrounding.groundedWhen("every other Saturday", in: "Clean the litter box") == "")
        #expect(DescribeChoresGrounding.groundedWhen("", in: "anything") == "")
    }

    @Test func roomsMustBeNamedInTheChoresOwnWords() {
        let rooms = ["Master Bath", "Kids Bath", "Kitchen"]
        // The household's own spelling wins.
        #expect(DescribeChoresGrounding.groundedRoom("kids' bathroom", scope: "Clean the kids' bathroom on Sundays", rooms: rooms) == "Kids Bath")
        // Named by the model but not in the chore's words: dropped (the model loves "Kitchen").
        #expect(DescribeChoresGrounding.groundedRoom("Kitchen", scope: "Pay the rent on the first", rooms: rooms) == "")
        // A new room the text names, title-cased, articles dropped.
        #expect(DescribeChoresGrounding.groundedRoom("the basement", scope: "empty the dehumidifier in the basement", rooms: []) == "Basement")
        // Not a room at all.
        #expect(DescribeChoresGrounding.groundedRoom("Gutters", scope: "Clean the gutters every spring", rooms: []) == "")
        // Two rooms: the first.
        #expect(DescribeChoresGrounding.groundedRoom("Living Room, Den", scope: "dust in the living room and den", rooms: ["Living Room", "Den"]) == "Living Room")
        // The model gave none, but the chore's words name one.
        #expect(DescribeChoresGrounding.groundedRoom("", scope: "Clean the kids' bathroom", rooms: rooms) == "Kids Bath")
        #expect(DescribeChoresGrounding.groundedRoom("", scope: "Scrub the tub in the upstairs bathroom", rooms: []) == "Upstairs Bathroom")
        #expect(DescribeChoresGrounding.groundedRoom("", scope: "laundry on Sundays", rooms: []) == "")   // "laundry" alone isn't a room
    }

    @Test func aChoresClauseIsWhereItsNameIs() {
        let text = "Dishes daily, laundry on Sundays, bathrooms on Saturdays"
        #expect(DescribeChoresGrounding.clause(for: "laundry", when: "Sundays", in: text) == "laundry on Sundays")
        #expect(DescribeChoresGrounding.clause(for: "Mop", when: "", in: "No match here") == "No match here")
    }

    @Test func groundedChoreReadsItsOwnSchedule() throws {
        let chore = try #require(DescribeChoresGrounding.chore(
            name: "Deep clean the bathroom", when: "every other Saturday", room: "Bathroom", cadence: .monthly,
            text: "Deep clean the bathroom every other Saturday", rooms: ["Bathroom", "Kitchen"]))
        #expect(chore.cadence == .weekly)           // the words beat the model's cadence
        #expect(chore.days == ["saturday"])
        #expect(chore.every == 2)
        #expect(chore.room == "Bathroom")
        #expect(DescribeChoresGrounding.chore(name: "Clean the kitchen", when: "", room: "Kitchen", cadence: .daily,
                                              text: "Thanks!", rooms: ["Kitchen"]) == nil)
    }

    @Test func dailyChoresDropDaysAndIntervals() throws {
        let chore = try #require(DescribeChoresGrounding.chore(
            name: "Walk the dog", when: "every other day", room: "", cadence: .weekly,
            text: "Walk the dog every other day", rooms: []))
        #expect(chore.cadence == .daily)
        #expect(chore.days.isEmpty)
        #expect(chore.every == 1)
    }

    // MARK: Prompts + errors

    @Test func promptListsRoomsThenTheText() {
        #expect(DescribeChoresPrompts.prompt(text: "  Mop Fridays \n", rooms: ["Kitchen", " ", "Den"])
                == "The household's rooms: Kitchen, Den.\nWhat they wrote:\nMop Fridays")
        #expect(DescribeChoresPrompts.prompt(text: "Mop", rooms: []) == "What they wrote:\nMop")
    }

    @Test func longTextIsCapped() {
        let long = String(repeating: "a", count: 5_000)
        #expect(DescribeChoresPrompts.clipText(long).count == DescribeChoresPrompts.maxTextLength)
    }

    @Test func textErrorsDontMentionPhotos() {
        for error in [RoomVisionError.unavailable, .unreadablePhoto, .declined, .busy, .failed] {
            #expect(!error.textMessage.localizedCaseInsensitiveContains("photo"))
        }
    }

    // MARK: Mapping

    private func chore(_ name: String, _ cadence: ChoreCadence, days: [String] = [], every: Int = 1,
                       room: String = "") -> DescribedChore {
        DescribedChore(name: name, cadence: cadence, days: days, every: every, room: room, when: "")
    }

    @Test func mappingSchedulesAndDedupes() throws {
        let kitchen = UUID()
        let result = DescribeChoresMapping.drafts(from: [
            chore("do the dishes", .daily),
            chore("Do the dishes", .daily),                       // repeat
            chore("   ", .weekly),                                 // blank
            chore("Mop the floor", .weekly, days: ["friday"], room: "kitchen"),
            chore("Change the air filter", .monthly),              // no day: spread
            chore("Wash the windows", .yearly, room: "Sunroom"),
        ], areas: [(id: kitchen, name: "Kitchen")], weekdayLoad: [.monday: 3], isPlus: false)

        let drafts = result.drafts
        #expect(drafts.map(\.name) == ["Do the dishes", "Mop the floor", "Change the air filter", "Wash the windows"])
        #expect(drafts[0].isDaily)
        #expect(drafts[1].frequency == .weekly && drafts[1].day == .friday && drafts[1].areaRef == .existing(kitchen))
        #expect(drafts[2].frequency == .monthly && drafts[2].day == .tuesday)   // Monday is the busy day
        #expect(drafts[3].areaRef == .new("Sunroom"))
        #expect(result.plusNotes.isEmpty)
    }

    @Test func plusSchedulesPassThroughWithPlus() throws {
        let result = DescribeChoresMapping.drafts(from: [
            chore("Deep clean the bathroom", .weekly, days: ["saturday"], every: 2),
            chore("Take out the trash", .weekly, days: ["monday", "thursday"]),
        ], areas: [], weekdayLoad: [:], isPlus: true)
        #expect(result.drafts[0].interval == 2)
        #expect(result.drafts[1].day == .monday)
        #expect(result.drafts[1].multiDays == [.monday, .thursday])
        #expect(result.plusNotes.isEmpty)
        #expect(result.drafts[0].scheduleSummary == "Every 2 weeks · Saturday")
        #expect(result.drafts[1].scheduleSummary == "Weekly · Mon, Thu")
    }

    @Test func plusSchedulesSimplifyWithoutPlus() throws {
        let result = DescribeChoresMapping.drafts(from: [
            chore("Deep clean the bathroom", .weekly, days: ["saturday"], every: 2),
            chore("Take out the trash", .weekly, days: ["monday", "thursday"]),
            chore("Make the bed", .weekly, days: ["monday", "tuesday", "wednesday", "thursday", "friday"]),
            chore("Test the smoke detectors", .monthly, every: 3),
        ], areas: [], weekdayLoad: [:], isPlus: false)
        let drafts = result.drafts
        #expect(drafts[0].interval == 1 && drafts[0].day == .saturday)
        #expect(result.plusNotes[drafts[0].id] == "Every 2 weeks needs Plus, so it's every week.")
        #expect(drafts[1].day == .monday && drafts[1].multiDays.isEmpty)
        #expect(result.plusNotes[drafts[1].id] == "More than one day a week needs Plus, so it's on Monday.")
        #expect(drafts[2].isDaily)
        #expect(result.plusNotes[drafts[2].id] == "Only some days a week needs Plus, so it's every day.")
        #expect(drafts[3].interval == 1)
        #expect(result.plusNotes[drafts[3].id] == "Every 3 months needs Plus, so it's every month.")
    }

    @Test func duplicatesAreCheckedPerRoomOrEverywhere() {
        let kitchen = UUID()
        let drafts = [
            ChoreDraft(name: "Do the dishes", isDaily: true),                              // no room: any room counts
            ChoreDraft(name: "Mop the floor", isDaily: false, areaRef: .existing(kitchen)),
            ChoreDraft(name: "Wipe the counters", isDaily: true, areaRef: .existing(kitchen)),
        ]
        let existing: (AreaRef) -> [String] = { ref in
            switch ref {
            case .none:             return ["Do the dishes", "Mop the floor"]   // every chore's name
            case .existing:         return ["Wipe down counters"]
            case .new:              return []
            }
        }
        let duplicates = DescribeChoresMapping.duplicates(in: drafts, existingNames: existing)
        #expect(duplicates == [drafts[0].id])
    }

    // MARK: Drafts

    @Test func normalizedKeepsOnlyWhatFits() {
        var draft = ChoreDraft(name: "Trash", isDaily: false, frequency: .weekly, day: .monday,
                               multiDays: [.monday, .thursday], interval: 2)
        #expect(draft.normalized() == draft)
        draft.day = .friday                                   // a single other day was picked
        #expect(draft.normalized().multiDays.isEmpty)
        draft.frequency = .monthly
        draft.day = .monday
        #expect(draft.normalized().multiDays.isEmpty)
        draft.isDaily = true
        let daily = draft.normalized()
        #expect(daily.day == nil && daily.interval == 1 && daily.multiDays.isEmpty)
    }

    @Test func commitWritesPlusSchedulesOnlyWhenAllowed() throws {
        let ctx = CoreDataStack(inMemory: true).newBackgroundContext()
        try ctx.performAndWait {
            let drafts = [
                ChoreDraft(name: "Trash", isDaily: false, frequency: .weekly, day: .monday,
                           multiDays: [.monday, .thursday], interval: 1),
                ChoreDraft(name: "Bathroom", isDaily: false, frequency: .weekly, day: .saturday, interval: 2),
            ]
            let plus = AddFlowCommit.commit(drafts, in: ctx, household: nil, allowsPlusSchedule: true)
            #expect(plus[0].assignedDaysValue == [.monday, .thursday])
            #expect(plus[1].recurrenceIntervalValue == 2)

            let free = AddFlowCommit.commit(drafts, in: ctx, household: nil)
            #expect(free[0].assignedDaysValue.isEmpty)
            #expect(free[0].assignedDayValue == .monday)
            #expect(free[1].recurrenceIntervalValue == 1)
            _ = try #require(plus.first)
        }
    }

    // MARK: Live model (opt-in)

    /// One real read on this runtime's on-device model. Opt-in (needs Apple Intelligence):
    /// `TEST_RUNNER_CHOREGANIZE_LIVE_FM=1 xcodebuild test … -only-testing:ChoreganizeTests/DescribeChoresTests/liveDescribeRoundTrip()`
    @Test(.enabled(if: ProcessInfo.processInfo.environment["CHOREGANIZE_LIVE_FM"] == "1"))
    func liveDescribeRoundTrip() async throws {
        #if canImport(FoundationModels)
        guard #available(iOS 27.0, macOS 27.0, *) else { return }
        try #require(RoomVisionAvailability.describeChores == .available)
        let (chores, usage) = try await DescribeChoresEngine.chores(
            from: "Deep clean the bathroom every other Saturday and do the dishes every night",
            rooms: ["Bathroom", "Kitchen"])
        #expect(chores.count == 2)
        let bathroom = try #require(chores.first { $0.name.localizedCaseInsensitiveContains("bathroom") })
        #expect(bathroom.cadence == .weekly && bathroom.days == ["saturday"] && bathroom.every == 2)
        #expect(chores.contains { $0.name.localizedCaseInsensitiveContains("dishes") && $0.cadence == .daily })
        #expect(usage.inputTokens > 0)
        let (none, _) = try await DescribeChoresEngine.chores(from: "Hello there!", rooms: ["Kitchen"])
        #expect(none.isEmpty)
        #endif
    }
}
