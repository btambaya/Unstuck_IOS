// App Shortcuts — the zero-setup Siri phrases. Registered automatically when the
// app launches (no Siri entitlement needed for App-Intents shortcuts). Each
// phrase MUST contain \(.applicationName) — that resolves to the app's display
// name, "UnstuckNow". The system also surfaces these in Spotlight and the
// Shortcuts app, and (for free) on Apple Watch + CarPlay.
//
// Apple caps a provider at ~10 shortcuts; keep the highest-value verbs here.

import AppIntents

struct UnstuckShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: PendingTaskCountIntent(),
            phrases: [
                "How many tasks do I have left in \(.applicationName)",
                "How many tasks are left in \(.applicationName)",
                "What's left to do in \(.applicationName)",
            ],
            shortTitle: "Tasks left",
            systemImageName: "checklist")

        AppShortcut(
            intent: NextTaskIntent(),
            phrases: [
                "What's my next task in \(.applicationName)",
                "What's next in \(.applicationName)",
                "What should I do next in \(.applicationName)",
            ],
            shortTitle: "Next task",
            systemImageName: "arrow.right.circle")

        AppShortcut(
            intent: TodayPlanIntent(),
            phrases: [
                "What's on my \(.applicationName) today",
                "What's on today in \(.applicationName)",
                "What's my \(.applicationName) plan",
            ],
            shortTitle: "Today's plan",
            systemImageName: "sun.max.fill")

        AppShortcut(
            intent: CreateTaskIntent(),
            phrases: [
                "Add a task in \(.applicationName)",
                "Create a task in \(.applicationName)",
                "New task in \(.applicationName)",
            ],
            shortTitle: "Add task",
            systemImageName: "plus.circle")

        AppShortcut(
            intent: CaptureThoughtIntent(),
            phrases: [
                "Capture a thought in \(.applicationName)",
                "Add to my \(.applicationName) inbox",
            ],
            shortTitle: "Capture",
            systemImageName: "tray.and.arrow.down")

        AppShortcut(
            intent: CompleteTaskIntent(),
            phrases: [
                "Complete \(\.$task) in \(.applicationName)",
                "Mark \(\.$task) done in \(.applicationName)",
                "Finish \(\.$task) in \(.applicationName)",
            ],
            shortTitle: "Complete task",
            systemImageName: "checkmark.circle")

        AppShortcut(
            intent: AddToListIntent(),
            phrases: [
                "Add to my \(\.$list) in \(.applicationName)",
                "Add an item to my \(\.$list) in \(.applicationName)",
            ],
            shortTitle: "Add to list",
            systemImageName: "text.badge.plus")

        AppShortcut(
            intent: StartFocusIntent(),
            phrases: [
                "Start a focus session in \(.applicationName)",
                "Start focus in \(.applicationName)",
                "Let's focus in \(.applicationName)",
            ],
            shortTitle: "Start focus",
            systemImageName: "timer")

        AppShortcut(
            intent: OpenTodayIntent(),
            phrases: [
                "Open \(.applicationName)",
                "Show my \(.applicationName) today",
            ],
            shortTitle: "Open today",
            systemImageName: "sun.max")
    }
}
