//
//  CompleterAttributionTests.swift
//  ChoreganizeTests
//
//  #59 — completer attribution: stamping rules on recordCompletion / markAllDone
//  and the pure id → display-name resolution.
//

import Testing
import CoreData
import Foundation
@testable import Choreganize

struct CompleterAttributionTests {

    // MARK: - Record-name canonicalisation (#99 picker dupe, 2-sim gate)

    @Test func ownerPlaceholderCanonicalisesToCurrentUser() {
        #expect(CompleterNameResolver.canonicalRecordName("__defaultOwner__", currentUserID: "_me") == "_me")
        // No cached identity yet: leave the placeholder alone rather than invent an id.
        #expect(CompleterNameResolver.canonicalRecordName("__defaultOwner__", currentUserID: nil) == "__defaultOwner__")
        // Real names pass through untouched.
        #expect(CompleterNameResolver.canonicalRecordName("_other", currentUserID: "_me") == "_other")
    }

    // MARK: - Stamping

    @Test func householdCompletionIsStamped() throws {
        let stack = CoreDataStack(inMemory: true)
        let ctx = stack.newBackgroundContext()
        try ctx.performAndWait {
            let household = CDHousehold(context: ctx)
            household.id = UUID(); household.name = "H"; household.createdDate = Date()
            let chore = CDChore.make(in: ctx, name: "Dishes", isDaily: true, household: household)
            try ctx.save()
            let completion = chore.recordCompletion(by: "_user123", in: ctx)
            #expect(completion?.completedBy == "_user123")
        }
    }

    @Test func soloCompletionIsNeverStamped() throws {
        let stack = CoreDataStack(inMemory: true)
        let ctx = stack.newBackgroundContext()
        try ctx.performAndWait {
            let chore = CDChore.make(in: ctx, name: "Dishes", isDaily: true, household: nil)
            try ctx.save()
            let completion = chore.recordCompletion(by: "_user123", in: ctx)
            #expect(completion?.completedBy == nil)
        }
    }

    @Test func missingIdentityLeavesCompletionUnattributed() throws {
        let stack = CoreDataStack(inMemory: true)
        let ctx = stack.newBackgroundContext()
        try ctx.performAndWait {
            let household = CDHousehold(context: ctx)
            household.id = UUID(); household.name = "H"; household.createdDate = Date()
            let chore = CDChore.make(in: ctx, name: "Dishes", isDaily: true, household: household)
            try ctx.save()
            let completion = chore.recordCompletion(by: nil, in: ctx)
            #expect(completion?.completedBy == nil)
        }
    }

    @Test func markAllDoneStampsByScope() throws {
        let stack = CoreDataStack(inMemory: true)
        let ctx = stack.newBackgroundContext()
        try ctx.performAndWait {
            let household = CDHousehold(context: ctx)
            household.id = UUID(); household.name = "H"; household.createdDate = Date()
            let shared = CDChore.make(in: ctx, name: "Shared", isDaily: true, household: household)
            let solo = CDChore.make(in: ctx, name: "Solo", isDaily: true, household: nil)
            try ctx.save()
            BulkChoreOps.markAllDone([shared.objectID, solo.objectID], on: Date(), by: "_user123", in: ctx)
            #expect(shared.completionsArray.first?.completedBy == "_user123")
            #expect(solo.completionsArray.first?.completedBy == nil)
        }
    }

    // MARK: - Resolution (pure)

    private func participant(_ id: String, given: String?, family: String? = nil) -> CompleterNameResolver.Participant {
        var components = PersonNameComponents()
        components.givenName = given
        components.familyName = family
        return .init(userRecordName: id, nameComponents: components)
    }

    @Test func nilIdHidesAttribution() {
        #expect(CompleterNameResolver.displayName(for: nil, currentUserID: "_me", participants: []) == nil)
    }

    @Test func ownCompletionIsHidden() {
        #expect(CompleterNameResolver.displayName(for: "_me", currentUserID: "_me",
                                                  participants: [participant("_me", given: "Spencer")]) == nil)
    }

    @Test func knownParticipantResolvesToShortName() {
        let name = CompleterNameResolver.displayName(for: "_syd", currentUserID: "_me",
                                                     participants: [participant("_syd", given: "Sydney", family: "Novalez")])
        #expect(name == "Sydney")
    }

    @Test func unknownIdFallsBackToGenericMember() {
        #expect(CompleterNameResolver.displayName(for: "_stranger", currentUserID: "_me", participants: [])
            == "A household member")
    }

    @Test func participantWithoutNameComponentsFallsBack() {
        let bare = CompleterNameResolver.Participant(userRecordName: "_syd", nameComponents: nil)
        #expect(CompleterNameResolver.displayName(for: "_syd", currentUserID: "_me", participants: [bare])
            == "A household member")
    }
}
