//
//  SharingTests.swift
//  ChoreganizeTests
//
//  Logic coverage for the Household sharing UI helpers.
//

import Testing
import CoreData
import Foundation
@testable import Choreganize

struct SharingTests {

    @Test func shareInfoStatusText() {
        #expect(HouseholdShareInfo.notShared.statusText == "Not shared yet")
        #expect(HouseholdShareInfo(isShared: true, acceptedCount: 1, pendingCount: 0, isOwner: true)
            .statusText == "Shared · 1 member")
        #expect(HouseholdShareInfo(isShared: true, acceptedCount: 2, pendingCount: 1, isOwner: true)
            .statusText == "Shared · 2 members · 1 pending")
    }

    @Test func renameUpdatesLocalNameTrimmed() throws {
        let stack = CoreDataStack(inMemory: true)   // cloudKitEnabled == false
        let ctx = stack.newBackgroundContext()
        try ctx.performAndWait {
            let household = CDHousehold(context: ctx)
            household.id = UUID(); household.name = "Old"; household.createdDate = Date()
            try ctx.save()
            HouseholdSharing.rename(household, to: "  New Name  ", stack: stack)
            #expect(household.name == "New Name")
        }
    }

    @Test func renameIgnoresBlank() throws {
        let stack = CoreDataStack(inMemory: true)
        let ctx = stack.newBackgroundContext()
        try ctx.performAndWait {
            let household = CDHousehold(context: ctx)
            household.id = UUID(); household.name = "Keep"; household.createdDate = Date()
            try ctx.save()
            HouseholdSharing.rename(household, to: "   ", stack: stack)
            #expect(household.name == "Keep")
        }
    }
}
