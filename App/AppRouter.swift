// Navigation state shared across the app so the FAB + command palette
// can drive tab + sheet from anywhere. (Port of the web's router intent.)

import SwiftUI
import UnstuckCore

@MainActor
@Observable
final class AppRouter {
    enum Tab: Hashable, CaseIterable { case today, tasks, calendar, lists }
    enum Sheet: Identifiable {
        case newTask, quickCapture
        var id: Int { hashValue }
    }

    var tab: Tab = .today
    var activeSheet: Sheet?
    /// When set, the Focus surface is presented full-screen for this task.
    var focusTask: TaskItem?

    func select(_ tab: Tab) { self.tab = tab }
    func present(_ sheet: Sheet) { activeSheet = sheet }
    func beginFocus(_ task: TaskItem) { focusTask = task }
}
