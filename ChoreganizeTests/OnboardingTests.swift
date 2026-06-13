//
//  OnboardingTests.swift
//  ChoreganizeTests
//
//  The onboarding coordinator's flow vs. replay decoupling.
//

import Testing
import Foundation
@testable import Choreganize

@MainActor
struct OnboardingTests {

    private func coordinator() -> OnboardingCoordinator {
        // Isolated defaults so tests don't touch the real "hasSeenOnboarding".
        let defaults = UserDefaults(suiteName: "onboarding-test-\(UUID().uuidString)")!
        return OnboardingCoordinator(defaults: defaults)
    }

    @Test func firstRunPlaysOnceThenStops() {
        let c = coordinator()
        #expect(c.hasSeenOnboarding == false)

        c.startFirstRunIfNeeded()
        #expect(c.current?.id == .welcome)

        while c.hasNext { c.advance() }   // walk to the last step
        c.advance()                       // finish the last step
        #expect(c.current == nil)
        #expect(c.hasSeenOnboarding == true)

        c.startFirstRunIfNeeded()         // a later launch must not re-auto-tour
        #expect(c.current == nil)
    }

    @Test func singleReplayIgnoresCompletion() {
        let c = coordinator()
        c.finish()                        // mark seen, nothing playing
        #expect(c.hasSeenOnboarding == true)

        c.play(OnboardingStep.step(.sharing))   // replay one step, post-completion
        #expect(c.current?.id == .sharing)
        #expect(c.hasNext == false)
        c.advance()
        #expect(c.current == nil)         // a single replay dismisses itself
    }

    @Test func pendingReplaySequencing() {
        let c = coordinator()
        c.requestReplay([OnboardingStep.step(.scope)])
        #expect(c.current == nil)         // queued, not yet playing
        c.playPendingIfNeeded()
        #expect(c.current?.id == .scope)  // plays once the host sheet dismisses
    }
}
