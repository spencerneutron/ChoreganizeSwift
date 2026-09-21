//
//  HouseholdEntitlementTests.swift
//  ChoreganizeTests
//
//  CG-15 / #97 — household-scoped Plus: the effective-gate OR rule and the
//  stamp/clear reconciliation on the synced CDHousehold.plusEnabled flag.
//

import Testing
import CoreData
import Foundation
@testable import Choreganize

@MainActor
struct HouseholdEntitlementTests {

    private func freshDefaults() -> UserDefaults {
        let suite = "test.householdPlus.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    private func makeHousehold(in ctx: NSManagedObjectContext) throws -> CDHousehold {
        let household = CDHousehold(context: ctx)
        household.id = UUID()
        household.name = "Testhold"
        household.createdDate = Date()
        try ctx.save()
        return household
    }

    // MARK: - Effective gate

    @Test func ownEntitlementUnlocks() {
        #expect(HouseholdEntitlement.effectiveIsPlus(ownPlus: true, household: nil))
    }

    @Test func householdFlagUnlocksWithoutOwnEntitlement() throws {
        let stack = CoreDataStack(inMemory: true)
        let household = try makeHousehold(in: stack.viewContext)
        household.plusEnabled = true
        #expect(HouseholdEntitlement.effectiveIsPlus(ownPlus: false, household: household))
    }

    @Test func neitherSideLocksTheGate() throws {
        let stack = CoreDataStack(inMemory: true)
        let household = try makeHousehold(in: stack.viewContext)
        #expect(!HouseholdEntitlement.effectiveIsPlus(ownPlus: false, household: household))
        #expect(!HouseholdEntitlement.effectiveIsPlus(ownPlus: false, household: nil))
    }

    // MARK: - Stamp reconciliation

    @Test func entitledMemberLightsTheFlag() throws {
        let stack = CoreDataStack(inMemory: true)
        let household = try makeHousehold(in: stack.viewContext)
        let defaults = freshDefaults()

        HouseholdEntitlement.syncStamp(household: household, isPlus: true, defaults: defaults)
        #expect(household.plusEnabled)
        #expect(defaults.bool(forKey: "householdPlus.setBy.\(household.id!.uuidString)"))
    }

    @Test func lapsedEntitlementClearsOnlyOwnFlag() throws {
        let stack = CoreDataStack(inMemory: true)
        let household = try makeHousehold(in: stack.viewContext)
        let defaults = freshDefaults()

        // We lit it, then lapsed: cleared.
        HouseholdEntitlement.syncStamp(household: household, isPlus: true, defaults: defaults)
        HouseholdEntitlement.syncStamp(household: household, isPlus: false, defaults: defaults)
        #expect(!household.plusEnabled)
    }

    @Test func someoneElsesFlagSurvivesOurLapse() throws {
        let stack = CoreDataStack(inMemory: true)
        let household = try makeHousehold(in: stack.viewContext)
        let defaults = freshDefaults()

        // Another member lit it (synced in); we were never entitled.
        household.plusEnabled = true
        HouseholdEntitlement.syncStamp(household: household, isPlus: false, defaults: defaults)
        #expect(household.plusEnabled)
    }

    @Test func stampIsIdempotent() throws {
        let stack = CoreDataStack(inMemory: true)
        let household = try makeHousehold(in: stack.viewContext)
        let defaults = freshDefaults()

        HouseholdEntitlement.syncStamp(household: household, isPlus: true, defaults: defaults)
        HouseholdEntitlement.syncStamp(household: household, isPlus: true, defaults: defaults)
        #expect(household.plusEnabled)
        HouseholdEntitlement.syncStamp(household: nil, isPlus: true, defaults: defaults)   // no crash
    }
}
