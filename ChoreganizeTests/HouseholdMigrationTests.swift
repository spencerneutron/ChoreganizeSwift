//
//  HouseholdMigrationTests.swift
//  ChoreganizeTests
//
//  CG-11 / #64 — Personal→Household migration: closure completeness, the
//  owner-side re-parent + journal, participant copy-and-retain semantics
//  (fresh UUIDs, provenance, idempotency, self-healing), and the store-scoped
//  Personal filter that keeps mid-migration records out of Personal lists.
//

import Testing
import CoreData
import Foundation
@testable import Choreganize

struct HouseholdMigrationTests {

    // MARK: - Helpers

    private func freshJournal() -> MigrationJournal {
        let suite = "test.migration.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return MigrationJournal(defaults: defaults)
    }

    @MainActor
    private func seedAreaGroup(in ctx: NSManagedObjectContext) throws -> (CDArea, [CDChore], [CDCompletion]) {
        let area = CDArea.make(in: ctx, name: "Kitchen", detail: "test", household: nil)
        let chore1 = CDChore.make(in: ctx, name: "Wipe counters", isDaily: true, household: nil)
        let chore2 = CDChore.make(in: ctx, name: "Mop floor", isDaily: false, frequency: .weekly, household: nil)
        chore1.area = area
        chore2.area = area
        let completion = CDCompletion.make(in: ctx, date: Date(), chore: chore1, household: nil)
        try ctx.save()
        return (area, [chore1, chore2], [completion])
    }

    @MainActor
    private func makeHousehold(in ctx: NSManagedObjectContext) throws -> CDHousehold {
        let household = CDHousehold(context: ctx)
        household.id = UUID()
        household.name = "Testhold"
        household.createdDate = Date()
        try ctx.save()
        return household
    }

    // MARK: - Closure completeness

    @MainActor
    @Test func closureCollectsWholeAreaGroup() throws {
        let stack = CoreDataStack(inMemory: true)
        let ctx = stack.viewContext
        let (area, chores, completions) = try seedAreaGroup(in: ctx)

        let closure = HouseholdMigration.closure(for: .init(areas: [area]))
        #expect(closure.count == 1 + chores.count + completions.count)
        #expect(closure.contains(area))
        for chore in chores { #expect(closure.contains(chore)) }
        for completion in completions { #expect(closure.contains(completion)) }
    }

    @MainActor
    @Test func closureCollectsLooseChoreWithCompletions() throws {
        let stack = CoreDataStack(inMemory: true)
        let ctx = stack.viewContext
        let chore = CDChore.make(in: ctx, name: "Take out trash", isDaily: true, household: nil)
        let completion = CDCompletion.make(in: ctx, date: Date(), chore: chore, household: nil)
        try ctx.save()

        let closure = HouseholdMigration.closure(for: .init(chores: [chore]))
        #expect(closure.count == 2)
        #expect(closure.contains(chore))
        #expect(closure.contains(completion))
    }

    // MARK: - Owner-side move

    @MainActor
    @Test func ownerMoveReparentsWholeClosureAndClearsJournal() async throws {
        let stack = CoreDataStack(inMemory: true)   // CloudKit off → no share leg
        let ctx = stack.viewContext
        let (area, chores, completions) = try seedAreaGroup(in: ctx)
        let household = try makeHousehold(in: ctx)
        let journal = freshJournal()

        let outcome = try await HouseholdMigration.migrate(
            .init(areas: [area]), into: household, stack: stack, journal: journal)

        #expect(outcome.mode == .ownerMove)
        #expect(outcome.migratedRoots == 1)
        #expect(area.household == household)
        for chore in chores { #expect(chore.household == household) }
        for completion in completions { #expect(completion.household == household) }
        #expect(journal.pendingMove == nil)
        // A move never duplicates: still exactly 2 chores in the store.
        let all = try ctx.fetch(NSFetchRequest<CDChore>(entityName: "CDChore"))
        #expect(all.count == 2)
    }

    @MainActor
    @Test func migrateRejectsEmptySelection() async throws {
        let stack = CoreDataStack(inMemory: true)
        let household = try makeHousehold(in: stack.viewContext)
        await #expect(throws: HouseholdMigration.MigrationError.self) {
            _ = try await HouseholdMigration.migrate(.init(), into: household, stack: stack, journal: freshJournal())
        }
    }

    // MARK: - Journal

    @Test func journalPendingMoveRoundTrip() {
        let journal = freshJournal()
        #expect(journal.pendingMove == nil)

        let ids = [UUID(), UUID()]
        let householdID = UUID()
        journal.beginPendingMove(ids: ids, householdID: householdID)
        let pending = journal.pendingMove
        #expect(pending?.ids == ids)
        #expect(pending?.householdID == householdID)

        journal.clearPendingMove()
        #expect(journal.pendingMove == nil)
    }

    @Test func journalContributionRoundTrip() {
        let journal = freshJournal()
        let original = UUID(), copy = UUID()
        #expect(journal.contributedCopyID(for: original) == nil)

        journal.recordContribution(original: original, copy: copy)
        #expect(journal.contributedCopyID(for: original) == copy)

        journal.clearContribution(for: original)
        #expect(journal.contributedCopyID(for: original) == nil)
    }

    // MARK: - Participant-side contribution

    @MainActor
    @Test func contributeCopiesWithFreshIDsAndRetainsOriginals() throws {
        let stack = CoreDataStack(inMemory: true)
        let ctx = stack.viewContext
        let (area, chores, completions) = try seedAreaGroup(in: ctx)
        let household = try makeHousehold(in: ctx)
        let journal = freshJournal()

        let copied = try HouseholdMigration.contribute(
            .init(areas: [area]), into: household, store: nil, context: ctx, journal: journal)
        #expect(copied == 1)

        // Originals retained, untouched, still Personal.
        #expect(area.household == nil)
        for chore in chores { #expect(chore.household == nil) }

        // Copies exist in the household with fresh identities and intact structure.
        let allAreas = try ctx.fetch(NSFetchRequest<CDArea>(entityName: "CDArea"))
        let copiedArea = try #require(allAreas.first { $0.household == household })
        #expect(copiedArea.id != area.id)
        #expect(copiedArea.name == area.name)
        #expect(copiedArea.choresArray.count == chores.count)
        for choreCopy in copiedArea.choresArray {
            #expect(choreCopy.household == household)
            #expect(!chores.map(\.id).contains(choreCopy.id))
        }
        let copiedCompletions = copiedArea.choresArray.flatMap(\.completionsArray)
        #expect(copiedCompletions.count == completions.count)
        #expect(copiedCompletions.allSatisfy { $0.household == household })

        // Provenance recorded for the root.
        #expect(journal.contributedCopyID(for: area.id!) == copiedArea.id)
    }

    @MainActor
    @Test func contributeIsIdempotent() throws {
        let stack = CoreDataStack(inMemory: true)
        let ctx = stack.viewContext
        let (area, _, _) = try seedAreaGroup(in: ctx)
        let household = try makeHousehold(in: ctx)
        let journal = freshJournal()

        let first = try HouseholdMigration.contribute(
            .init(areas: [area]), into: household, store: nil, context: ctx, journal: journal)
        let second = try HouseholdMigration.contribute(
            .init(areas: [area]), into: household, store: nil, context: ctx, journal: journal)
        #expect(first == 1)
        #expect(second == 0)

        let householdAreas = try ctx.fetch(NSFetchRequest<CDArea>(entityName: "CDArea"))
            .filter { $0.household == household }
        #expect(householdAreas.count == 1)
    }

    @MainActor
    @Test func staleProvenanceHealsAndRecopies() throws {
        let stack = CoreDataStack(inMemory: true)
        let ctx = stack.viewContext
        let chore = CDChore.make(in: ctx, name: "Dust shelves", isDaily: true, household: nil)
        try ctx.save()
        let household = try makeHousehold(in: ctx)
        let journal = freshJournal()

        // Provenance pointing at a copy that never materialized (interrupted save).
        journal.recordContribution(original: chore.id!, copy: UUID())
        #expect(HouseholdMigration.isContributed(chore.id, in: ctx, journal: journal) == false)

        // The stale entry was cleared, so contribution proceeds — exactly one copy.
        let copied = try HouseholdMigration.contribute(
            .init(chores: [chore]), into: household, store: nil, context: ctx, journal: journal)
        #expect(copied == 1)
        let copies = try ctx.fetch(NSFetchRequest<CDChore>(entityName: "CDChore"))
            .filter { $0.household == household }
        #expect(copies.count == 1)
    }

    // MARK: - Store-scoped Personal filter (the CG-11 leak fix)

    @MainActor
    @Test func personalScopeExcludesSharedStoreRecords() throws {
        // Two on-disk stores over the shared model stand in for private/shared.
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("migration-scope-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let container = NSPersistentContainer(name: "ScopeTest", managedObjectModel: CoreDataStack.managedObjectModel)
        let first = NSPersistentStoreDescription(url: dir.appendingPathComponent("a.sqlite"))
        let second = NSPersistentStoreDescription(url: dir.appendingPathComponent("b.sqlite"))
        container.persistentStoreDescriptions = [first, second]
        container.loadPersistentStores { _, error in precondition(error == nil) }
        let coordinator = container.persistentStoreCoordinator
        let privateStore = coordinator.persistentStore(for: first.url!)!
        let sharedStore = coordinator.persistentStore(for: second.url!)!

        let ctx = container.viewContext
        let personal = CDChore.make(in: ctx, name: "Truly personal", isDaily: true, household: nil)
        ctx.assign(personal, to: privateStore)
        let midMigration = CDChore.make(in: ctx, name: "Mid-migration leak", isDaily: true, household: nil)
        ctx.assign(midMigration, to: sharedStore)
        try ctx.save()

        let all = try ctx.fetch(NSFetchRequest<CDChore>(entityName: "CDChore"))
        #expect(all.count == 2)

        // The store-aware filter keeps the shared-store record out of Personal…
        let scoped = all.inScope(nil, sharedStore: sharedStore)
        #expect(scoped.map(\.objectID) == [personal.objectID])

        // …and stays permissive when no shared store exists (solo installs, tests).
        let unscoped = all.inScope(nil, sharedStore: nil)
        #expect(unscoped.count == 2)
    }

    @MainActor
    @Test func unsavedInsertsCountAsPersonal() throws {
        let stack = CoreDataStack(inMemory: true)
        let ctx = stack.viewContext
        let draft = CDChore.make(in: ctx, name: "Unsaved draft", isDaily: true, household: nil)
        // Not saved: no persistent store yet. Must still appear in Personal.
        let scoped = [draft].inScope(nil, sharedStore: nil)
        #expect(scoped.count == 1)
    }
}
