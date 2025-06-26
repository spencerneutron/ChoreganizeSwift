//
//  ChoreganizeTests.swift
//  ChoreganizeTests
//
//  Created by Spencer Van Keuren on 6/18/25.
//

import Testing

struct ChoreganizeTests {

    @Test func example() async throws {
        // Write your test here and use APIs like `#expect(...)` to check expected conditions.
    }

    @Test func testEditChore() async throws {
        let model = AppModel()
        let chore = Chore(name: "Test", frequency: .daily, assignedDay: .monday, areaId: nil)
        model.addChore(chore)
        var updated = chore
        updated.name = "Updated"
        updated.assignedDay = .tuesday
        model.updateChore(updated)
        #expect(model.chores.first?.name == "Updated")
        #expect(model.chores.first?.assignedDay == .tuesday)
    }

}
