import AppIntents

/// Zero-setup Siri phrases for the chore intents. Every phrase must contain the
/// app name token `\(.applicationName)`, which matches the primary name
/// "Choreganize" **and** the "Chores" alias (Info.plist `INAlternativeAppNames`).
/// So the same phrase reads as either "…Choreganize tasks…" or "…Chores…".
struct ChoreShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: TodaysChoresIntent(),
            phrases: [
                // This first phrase is what the Hub's SiriTipView displays, so it
                // leads with the literal word "chores" and positions
                // \(.applicationName) as the app — "What chores do I have today in
                // Choreganize". (\(.applicationName) always *displays* the primary app
                // name; the "Chores" alias only affects what Siri *recognises*, so it
                // can't be forced to display in its place.) The remaining phrases keep
                // the token-as-noun forms purely to widen recognition.
                "What chores do I have today in \(.applicationName)",
                "What \(.applicationName) do I have today",
                "What \(.applicationName) do I have to do today",
                "What are my \(.applicationName) today",
                "What are my \(.applicationName) tasks today",
                "Show my \(.applicationName) tasks for today"
            ],
            shortTitle: "Today's Chores",
            systemImageName: "checklist"
        )
        AppShortcut(
            intent: CompleteChoreIntent(),
            phrases: [
                "Complete a \(.applicationName) task",
                "Mark a \(.applicationName) task complete",
                "Complete \(\.$chore) in \(.applicationName)",
                "Mark \(\.$chore) complete in \(.applicationName)"
            ],
            shortTitle: "Complete a Chore",
            systemImageName: "checkmark.circle"
        )
    }
}
