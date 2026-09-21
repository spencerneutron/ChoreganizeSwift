//
//  MemberCompletionPolicyTests.swift
//  ChoreganizeTests
//
//  CG-14 / #62 — the pure notify-or-not decision for member-completion
//  notifications. The history/UN delivery plumbing is exercised at the 2-sim
//  release gate; the decision matrix is pinned here.
//

import Testing
import Foundation
@testable import Choreganize

struct MemberCompletionPolicyTests {

    private let now = Date(timeIntervalSince1970: 1_780_000_000)

    private func event(by: String? = "_other",
                       age: TimeInterval = 60,
                       household: Bool = true) -> MemberCompletionPolicy.Event {
        .init(completedBy: by, date: now.addingTimeInterval(-age), isHousehold: household)
    }

    @Test func anotherMembersFreshHouseholdCompletionNotifies() {
        #expect(MemberCompletionPolicy.shouldNotify(
            event: event(), currentUserID: "_me", isPlus: true, isEnabled: true, now: now))
    }

    @Test func ownCompletionNeverNotifies() {
        #expect(!MemberCompletionPolicy.shouldNotify(
            event: event(by: "_me"), currentUserID: "_me", isPlus: true, isEnabled: true, now: now))
    }

    @Test func unattributedCompletionNeverNotifies() {
        #expect(!MemberCompletionPolicy.shouldNotify(
            event: event(by: nil), currentUserID: "_me", isPlus: true, isEnabled: true, now: now))
    }

    @Test func soloCompletionNeverNotifies() {
        #expect(!MemberCompletionPolicy.shouldNotify(
            event: event(household: false), currentUserID: "_me", isPlus: true, isEnabled: true, now: now))
    }

    @Test func staleCompletionDoesNotNotify() {
        // Past the recency window AND not today (26h is yesterday in every
        // time zone): an overnight sync shouldn't bulldoze.
        #expect(!MemberCompletionPolicy.shouldNotify(
            event: event(age: 26 * 60 * 60),
            currentUserID: "_me", isPlus: true, isEnabled: true, now: now))
    }

    @Test func dayNormalizedCompletionNotifiesAllDay() {
        // Completion dates are stored as local midnight. Late in the day the
        // wall-clock gap is far past the window, but it is still today's
        // completion — this is the 2-sim gate regression (20:55 never notified).
        let cal = Calendar.current
        let midnight = cal.startOfDay(for: now)
        let lateToday = cal.date(byAdding: .hour, value: 21, to: midnight)!
        #expect(MemberCompletionPolicy.shouldNotify(
            event: .init(completedBy: "_other", date: midnight, isHousehold: true),
            currentUserID: "_me", isPlus: true, isEnabled: true, now: lateToday, calendar: cal))
    }

    @Test func yesterdaysDayNormalizedCompletionDoesNotNotify() {
        // Yesterday's checkmark syncing in just after midnight stays quiet.
        let cal = Calendar.current
        let midnight = cal.startOfDay(for: now)
        let yesterday = cal.date(byAdding: .day, value: -1, to: midnight)!
        let earlyToday = cal.date(byAdding: .minute, value: 30, to: midnight)!
        #expect(!MemberCompletionPolicy.shouldNotify(
            event: .init(completedBy: "_other", date: yesterday, isHousehold: true),
            currentUserID: "_me", isPlus: true, isEnabled: true, now: earlyToday, calendar: cal))
    }

    @Test func farFutureDateDoesNotNotify() {
        #expect(!MemberCompletionPolicy.shouldNotify(
            event: event(age: -(MemberCompletionPolicy.futureTolerance + 1)),
            currentUserID: "_me", isPlus: true, isEnabled: true, now: now))
        // Small clock skew is tolerated.
        #expect(MemberCompletionPolicy.shouldNotify(
            event: event(age: -60), currentUserID: "_me", isPlus: true, isEnabled: true, now: now))
    }

    @Test func gatesSuppressNotification() {
        #expect(!MemberCompletionPolicy.shouldNotify(
            event: event(), currentUserID: "_me", isPlus: false, isEnabled: true, now: now))
        #expect(!MemberCompletionPolicy.shouldNotify(
            event: event(), currentUserID: "_me", isPlus: true, isEnabled: false, now: now))
    }

    @Test func unknownLocalIdentityStillNotifiesForStampedImports() {
        // Everything this device stamps carries its cached id, so a stamped
        // import while we're id-less must be someone else's completion.
        #expect(MemberCompletionPolicy.shouldNotify(
            event: event(), currentUserID: nil, isPlus: true, isEnabled: true, now: now))
    }

    @Test func bodyFormatsChoreAndCompleter() {
        #expect(MemberCompletionPolicy.body(choreName: "Dishes", completerName: "Sydney")
            == "Sydney completed Dishes.")
        #expect(MemberCompletionPolicy.body(choreName: nil, completerName: "Sydney")
            == "Sydney completed a chore.")
    }
}
