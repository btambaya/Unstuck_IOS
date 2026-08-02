// Ported from lib/assistant/receipts.test.ts. A receipt is the app's claim
// about what changed, so it must come from the executor's structured result —
// never from model prose — and its Undo must target the real row.

import XCTest
@testable import UnstuckCore

final class AssistantReceiptsTests: XCTestCase {

    private func task(id: String = "t1", name: String = "Report", done: Bool = false,
                      completedAt: String? = nil) -> TaskItem {
        TaskItem(id: id, name: name, estimateMin: 25, totalFocused: 0, done: done,
                 completedAt: completedAt,
                 createdAt: "2026-08-01T10:00:00Z", updatedAt: "2026-08-01T10:00:00Z")
    }

    // MARK: deriveReceipt

    func testCreateTaskGetsADeleteUndoCarryingTheCreatedId() {
        let r = deriveReceipt(name: "create_task", args: ReceiptArgs(),
                              result: "ok: created task id=abc123 name=\"Dentist\"", tasks: [])
        XCTAssertEqual(r, Receipt(icon: .plus, label: "Created “Dentist”", undo: .deleteTask(id: "abc123")))
    }

    func testScheduleTaskCarriesDateAndTimeFromArgs() {
        let r = deriveReceipt(name: "schedule_task",
                              args: ReceiptArgs(date: "2026-08-04", startTime: "15:00"),
                              result: "ok: scheduled \"Dentist\" 2026-08-04 15:00", tasks: [])
        XCTAssertEqual(r?.label, "Scheduled “Dentist” · 2026-08-04 15:00")
        XCTAssertNil(r?.undo)
    }

    func testCompleteTaskFindsTheCompletedTaskForTheUncompleteUndo() {
        let done = task(id: "x9", name: "Report", done: true)
        let r = deriveReceipt(name: "complete_task", args: ReceiptArgs(),
                              result: "ok: completed \"Report\"", tasks: [done])
        XCTAssertEqual(r?.undo, .uncompleteTask(id: "x9"))
        XCTAssertTrue(r?.isUndoable ?? false)
    }

    func testFailedResultsProduceNoReceipt() {
        XCTAssertNil(deriveReceipt(name: "create_task", args: ReceiptArgs(),
                                   result: "error: nope", tasks: []))
    }

    func testReadOnlyAndUnknownToolsProduceNoReceipt() {
        XCTAssertNil(deriveReceipt(name: "list_tasks", args: ReceiptArgs(),
                                   result: "ok: 3 tasks", tasks: []))
    }

    func testLaterAndRecurrenceReceiptsNameTheTaskFromTheLiveStore() {
        let t = task(id: "t7", name: "Taxes")
        let parked = deriveReceipt(name: "set_task_later", args: ReceiptArgs(taskId: "t7", later: true),
                                   result: "ok", tasks: [t])
        XCTAssertEqual(parked?.label, "Moved to Later — “Taxes”")
        let back = deriveReceipt(name: "set_task_later", args: ReceiptArgs(taskId: "t7", later: false),
                                 result: "ok", tasks: [t])
        XCTAssertEqual(back?.label, "Brought back from Later — “Taxes”")

        let weekly = deriveReceipt(name: "set_task_recurrence", args: ReceiptArgs(taskId: "t7", kind: "weekly"),
                                   result: "ok", tasks: [t])
        XCTAssertEqual(weekly?.label, "Repeats weekly — “Taxes”")
        let cleared = deriveReceipt(name: "set_task_recurrence", args: ReceiptArgs(taskId: "t7"),
                                    result: "ok", tasks: [t])
        XCTAssertEqual(cleared?.label, "Repeat removed — “Taxes”")
    }

    func testTheRemainingWriteToolsEachGetTheirOwnGlyph() {
        XCTAssertEqual(deriveReceipt(name: "update_task", args: ReceiptArgs(),
                                     result: "ok: updated \"Report\"", tasks: [])?.icon, .pencil)
        XCTAssertEqual(deriveReceipt(name: "delete_task", args: ReceiptArgs(),
                                     result: "ok: deleted \"Report\"", tasks: [])?.icon, .trash)
        XCTAssertEqual(deriveReceipt(name: "create_list", args: ReceiptArgs(),
                                     result: "ok: created list id=l1 name=\"Groceries\"", tasks: [])?.label,
                       "Created list “Groceries”")
        XCTAssertEqual(deriveReceipt(name: "add_to_list", args: ReceiptArgs(),
                                     result: "ok: added to \"Groceries\"", tasks: [])?.label,
                       "Added to “Groceries”")
        XCTAssertEqual(deriveReceipt(name: "promote_item_to_task", args: ReceiptArgs(),
                                     result: "ok: promoted \"Milk\"", tasks: [])?.label,
                       "Promoted “Milk” to a task")
    }

    func testAnUnnamedResultFallsBackToAGenericNounRatherThanLying() {
        XCTAssertEqual(deriveReceipt(name: "update_task", args: ReceiptArgs(), result: "ok", tasks: [])?.label,
                       "Updated “task”")
    }

    // MARK: planReceiptUndo

    func testDeleteUndoRemovesTheCreatedTask() {
        XCTAssertEqual(planReceiptUndo(.deleteTask(id: "abc"), tasks: [], nowISO: "2026-08-02T10:00:00Z"),
                       .deleteTask(id: "abc"))
    }

    func testUncompleteUndoFlipsDoneBackOffAndClearsTheStamp() {
        let t = task(id: "x9", done: true, completedAt: "2026-08-02T10:00:00Z")
        let action = planReceiptUndo(.uncompleteTask(id: "x9"), tasks: [t], nowISO: "2026-08-02T11:00:00Z")
        guard case .restoreTask(let restored)? = action else { return XCTFail("expected a restore") }
        XCTAssertFalse(restored.done)
        XCTAssertNil(restored.completedAt)
        XCTAssertEqual(restored.updatedAt, "2026-08-02T11:00:00Z")
    }

    func testUncompleteUndoOfAMissingTaskPlansNothing() {
        XCTAssertNil(planReceiptUndo(.uncompleteTask(id: "gone"), tasks: [], nowISO: "2026-08-02T10:00:00Z"))
    }

    func testReceiptsRoundTripThroughTheThreadPersistence() throws {
        let r = Receipt(icon: .check, label: "Completed “Report”", undo: .uncompleteTask(id: "x9"), undone: true)
        let back = try JSONDecoder().decode(Receipt.self, from: JSONEncoder().encode(r))
        XCTAssertEqual(back, r)
        XCTAssertFalse(back.isUndoable, "an already-used undo must not come back after a relaunch")
    }
}
