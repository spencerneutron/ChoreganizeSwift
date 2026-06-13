import SwiftUI

/// A self-contained onboarding step. Steps are pure data with no knowledge of
/// ordering or completion, so the same step can play in the first-run tour or be
/// replayed on its own from Help.
struct OnboardingStep: Identifiable, Equatable {
    /// A real on-screen control a step can spotlight (wired up in chunk 2; until
    /// then a spotlight step simply presents as a card).
    enum Spotlight: String, Equatable {
        case modePicker, scopeSwitch, doneButton
    }

    enum ID: String, CaseIterable, Identifiable, Equatable {
        case welcome, modes, scheduling, scope, sharing, finishDay
        var id: String { rawValue }
    }

    let id: ID
    let title: String
    let message: String
    let systemImage: String
    let spotlight: Spotlight?

    init(_ id: ID, title: String, message: String, systemImage: String, spotlight: Spotlight? = nil) {
        self.id = id
        self.title = title
        self.message = message
        self.systemImage = systemImage
        self.spotlight = spotlight
    }
}

extension OnboardingStep {
    /// Every step, in tour order.
    static let all: [OnboardingStep] = [
        .init(.welcome,
              title: "Welcome to Choreganize",
              message: "Organize your household's chores and share them with the people you live with. Here's a quick tour — you can replay any of it later from Support.",
              systemImage: "checklist"),
        .init(.modes,
              title: "Three views",
              message: "Use the bar at the bottom to move between Work (today's checklist), Edit (manage chores & areas), and Calendar (the month at a glance).",
              systemImage: "rectangle.3.group",
              spotlight: .modePicker),
        .init(.scheduling,
              title: "Daily or scheduled",
              message: "Mark a chore “Every Day,” or give it a weekly, monthly, or yearly rhythm on a chosen day. Choreganize tracks when each one is due and flags overdue ones.",
              systemImage: "calendar.badge.clock"),
        .init(.scope,
              title: "Solo & Household",
              message: "Keep personal tasks in Solo and shared ones in your Household. Tap here anytime to switch between them.",
              systemImage: "person.2",
              spotlight: .scopeSwitch),
        .init(.sharing,
              title: "Share your Household",
              message: "Open the Household menu to invite others. Everyone in a Household can add, edit, and complete chores together.",
              systemImage: "square.and.arrow.up"),
        .init(.finishDay,
              title: "Finish the day",
              message: "Tap Done to wrap up a day. Past days lock automatically so your history stays accurate — but feel free to work ahead!",
              systemImage: "checkmark.seal",
              spotlight: .doneButton),
    ]

    /// The step with the given id (every id is present in `all`).
    static func step(_ id: ID) -> OnboardingStep { all.first { $0.id == id }! }
}
