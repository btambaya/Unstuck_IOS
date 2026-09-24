// Ported from lib/assistant/receipts.test.ts (+ the 2026-09-02 full-surface
// cases). A receipt is the app's claim about what changed, so it must come
// from the executor's structured result — never from model prose — and its
// Undo must target the real row.

import XCTest
@testable import UnstuckCore

final class AssistantReceiptsTests: XCTestCase {

    private func task(id: String = "t1", name: String = "Report", done: Bool = false,
                      moveCount: Int? = nil, completedAt: String? = nil) -> TaskItem {
        TaskItem(id: id, name: name, estimateMin: 25, totalFocused: 0, done: done, moveCount: moveCount,
                 completedAt: completedAt,
                 createdAt: "2026-08-01T10:00:00Z", updatedAt: "2026-08-01T10:00:00Z")
    }

    // The web vectors are 24-hour; the 12-hour cards are pinned separately.
    private func r(_ name: String, _ result: String, args: ReceiptArgs = ReceiptArgs(), tasks: [TaskItem] = [],
                   tone: Tone = .gentle, clock: ClockFormat = .h24) -> Receipt? {
        deriveReceipt(name: name, args: args, result: result, tasks: tasks, tone: tone, clock: clock)
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
                              result: "ok: scheduled \"Dentist\" 2026-08-04 15:00", tasks: [], clock: .h24)
        XCTAssertEqual(r?.label, "Scheduled “Dentist” · 2026-08-04 15:00")
        XCTAssertNil(r?.undo)
    }

    /// The card shows the time in the user's clock; the tool's "15:00" is
    /// machine format (2026-09-24).
    func testReceiptTimesFollowTheClock() {
        let args = ReceiptArgs(date: "2026-08-04", startTime: "15:00")
        let result = "ok: scheduled \"Dentist\" 2026-08-04 15:00"
        XCTAssertEqual(deriveReceipt(name: "schedule_task", args: args, result: result, tasks: [], clock: .h12)?.label,
                       "Scheduled “Dentist” · 2026-08-04 3:00 PM")
        XCTAssertEqual(deriveReceipt(name: "schedule_task", args: args, result: result, tasks: [], clock: .h24)?.label,
                       "Scheduled “Dentist” · 2026-08-04 15:00")
        XCTAssertEqual(r("request_call", "ok: call booked 2026-09-03 14:45 \"speak to James\" (1 note) id=cr1", clock: .h12)?.label,
                       "Call booked Thu 2:45 PM — speak to James · 1 note")
        XCTAssertEqual(r("update_call", "ok: updated call \"speak to James\" — 2026-09-04 09:00, 2 notes", clock: .h12)?.label,
                       "Call updated Fri 9:00 AM — speak to James · 2 notes")
    }

    func testCompleteTaskFindsTheCompletedTaskForTheUncompleteUndo() {
        let done = task(id: "x9", name: "Report", done: true)
        let r = deriveReceipt(name: "complete_task", args: ReceiptArgs(),
                              result: "ok: completed \"Report\"", tasks: [done])
        XCTAssertEqual(r?.undo, .uncompleteTask(id: "x9"))
        XCTAssertTrue(r?.isUndoable ?? false)
    }

    func testCompleteTaskPrefersTheExecutorsIdOverTheName() {
        // Two "Report"s — the id in the result picks the right duplicate (flow review, 2026-08-30).
        let a = task(id: "a", name: "Report", done: true)
        let b = task(id: "b", name: "Report", done: true)
        let r = deriveReceipt(name: "complete_task", args: ReceiptArgs(),
                              result: "ok: completed \"Report\" id=b", tasks: [a, b])
        XCTAssertEqual(r?.undo, .uncompleteTask(id: "b"))
    }

    func testCompleteTaskCelebratesAQuietWinInTheUsersTone() {
        let dodger = task(id: "x9", name: "Tax return", done: true, moveCount: 4)
        XCTAssertEqual(r("complete_task", "ok: completed \"Tax return\" id=x9", tasks: [dodger])?.label,
                       "“Tax return” finally happened — it dodged you 4 times, and you got it anyway.")
        XCTAssertEqual(r("complete_task", "ok: completed \"Tax return\" id=x9", tasks: [dodger], tone: .honest)?.label,
                       "That’s “Tax return” done after 4 dodges. The hard kind of done.")
        // An ordinary completion keeps the plain label.
        XCTAssertEqual(r("complete_task", "ok: completed \"Report\" id=t1", tasks: [task(done: true)])?.label, "Completed “Report”")
    }

    func testFailedResultsProduceNoReceipt() {
        XCTAssertNil(deriveReceipt(name: "create_task", args: ReceiptArgs(),
                                   result: "error: nope", tasks: []))
    }

    func testReadOnlyAndUnknownToolsProduceNoReceipt() {
        XCTAssertNil(r("list_tasks", "ok: 3 tasks"))
        XCTAssertNil(r("get_schedule", "ok:\nMonday 2026-09-07 (TODAY): —"))
        XCTAssertNil(r("get_tasks", "ok: 2 tasks"))
        XCTAssertNil(r("get_captures", "ok: 0 open captures"))
        XCTAssertNil(r("get_insights", "ok: Insights, week so far"))
        XCTAssertNil(r("open_screen", "ok: opened today"))
        XCTAssertNil(r("share_task", "ok: staged"))
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
        // kind "none" is the stop, never "Repeats none" (web parity, 2026-09-24).
        let stopped = deriveReceipt(name: "set_task_recurrence", args: ReceiptArgs(taskId: "t7", kind: "none"),
                                    result: "ok: \"Taxes\" no longer repeats", tasks: [t])
        XCTAssertEqual(stopped?.label, "Repeat removed — “Taxes”")
        // Every N weeks reads the rhythm from the RESULT (every-n-weeks spec
        // §7.3): an omitted intervalWeeks can still keep N, and a change back
        // to every week names the old N after "now".
        let fortnightly = deriveReceipt(name: "set_task_recurrence", args: ReceiptArgs(taskId: "t7", kind: "weekly"),
                                        result: "ok: \"Taxes\" now repeats every 2 weeks on Thu at 10:30 — next Thu 24 Sep (today), then Thu 8 Oct",
                                        tasks: [t])
        XCTAssertEqual(fortnightly?.label, "Repeats every 2 weeks — “Taxes”")
        let backToWeekly = deriveReceipt(name: "set_task_recurrence", args: ReceiptArgs(taskId: "t7", kind: "weekly"),
                                         result: "ok: \"Taxes\" now repeats weekly on Thu at 10:30 — every week now; it was every 2 weeks",
                                         tasks: [t])
        XCTAssertEqual(backToWeekly?.label, "Repeats weekly — “Taxes”")
        XCTAssertEqual(repeatsEveryNWeeks("ok: \"Every 3 weeks club\" now repeats every 8 weeks on Mon"), 8)
        XCTAssertNil(repeatsEveryNWeeks("ok: \"X\" now repeats every day"))
    }

    /// An ok whose wish was already true changed nothing — no card claiming a
    /// change (Zubair's call, 2026-09-24; web receipts.ts NOTHING_TO_CHANGE).
    func testAnOkThatChangedNothingGetsNoReceipt() {
        let t = task(id: "t7", name: "Office Focus")
        XCTAssertNil(deriveReceipt(name: "set_task_recurrence", args: ReceiptArgs(taskId: "t7", kind: "none"),
                                   result: "ok: \"Office Focus\" already doesn't repeat" + NOTHING_TO_CHANGE, tasks: [t]))
        XCTAssertNil(deriveReceipt(name: "schedule_task", args: ReceiptArgs(taskId: "t7", date: "2026-09-24", startTime: "10:30"),
                                   result: "ok: \"Office Focus\" is already on 2026-09-24 at 10:30" + NOTHING_TO_CHANGE, tasks: [t]))
        XCTAssertEqual(NOTHING_TO_CHANGE, " — nothing to change")
    }

    func testTheRemainingWriteToolsEachGetTheirOwnGlyph() {
        XCTAssertEqual(r("update_task", "ok: updated \"Report\"")?.icon, .pencil)
        XCTAssertEqual(r("delete_task", "ok: deleted \"Report\"")?.icon, .trash)
        XCTAssertEqual(r("create_list", "ok: created list id=l1 name=\"Groceries\"")?.label, "Created list “Groceries”")
        XCTAssertEqual(r("add_to_list", "ok: added to \"Groceries\"")?.label, "Added to “Groceries”")
        XCTAssertEqual(r("promote_item_to_task", "ok: promoted \"Milk\"")?.label, "Promoted “Milk” to a task")
    }

    func testAnUnnamedResultFallsBackToAGenericNounRatherThanLying() {
        XCTAssertEqual(r("update_task", "ok")?.label, "Updated “task”")
    }

    func testQuotedNamesSpanTheOutermostQuotes() {
        XCTAssertEqual(r("update_task", "ok: updated \"Say \"hi\" to Sam\"")?.label, "Updated “Say \"hi\" to Sam”")
    }

    // MARK: bulk + profile

    func testBulkCreateAndCompleteCarryTheirIdsForUndo() {
        XCTAssertEqual(r("create_tasks", "ok: created 3 tasks ids=a,b,c — \"One\", \"Two\", \"Three\""),
                       Receipt(icon: .plus, label: "Created 3 tasks", undo: .deleteTasks(ids: ["a", "b", "c"])))
        XCTAssertEqual(r("complete_tasks", "ok: completed 2 tasks ids=x,y"),
                       Receipt(icon: .check, label: "Completed 2 tasks", undo: .uncompleteTasks(ids: ["x", "y"])))
        // No ids → no undo, and an unparseable count reads "?".
        XCTAssertEqual(r("create_tasks", "ok: created tasks"), Receipt(icon: .plus, label: "Created ? tasks"))
    }

    func testSaveProfileFactIsTheConsentReceiptWithAForgetUndo() {
        XCTAssertEqual(r("save_profile_fact", "ok: remembered id=f1 \"Sam — partner, works night shifts\""),
                       Receipt(icon: .pencil, label: "Noted: Sam — partner, works night shifts", undo: .forgetFact(id: "f1")))
        XCTAssertEqual(r("forget_fact", "ok: forgot \"Sam — partner\"")?.label, "Forgot: Sam — partner")
    }

    // MARK: full app surface (2026-09-02)

    func testTaskAndOccurrenceTools() {
        XCTAssertEqual(r("uncomplete_task", "ok: reopened \"Report\" id=t1"),
                       Receipt(icon: .check, label: "Reopened Report", undo: .completeTask(id: "t1")))
        XCTAssertEqual(r("unschedule_task", "ok: unscheduled \"Report\" (task kept, 1 slot removed)")?.label, "Unscheduled Report")
        XCTAssertEqual(r("skip_occurrence", "ok: skipped \"Gym\" on 2026-09-02 (the task and its other days stay)")?.label, "Skipped Gym today")
        XCTAssertEqual(r("complete_occurrence", "ok: marked \"Gym\" done for 2026-09-02 (series continues)")?.label, "Done for today: Gym")
        XCTAssertEqual(r("block_time", "ok: blocked \"Dentist\" 2026-09-03 10:00 for 60m id=bt1"),
                       Receipt(icon: .calendar, label: "Blocked Dentist", undo: .deleteTask(id: "bt1")))
        XCTAssertEqual(r("carry_to_tomorrow", "ok: carried 2 to 2026-09-03 — \"Report\", \"Gym\"")?.label, "carried 2 to 2026-09-03")
    }

    func testFocusTools() {
        XCTAssertEqual(r("start_focus", "ok: focus started on \"Report\" (25m) — the user is now on the focus screen"),
                       Receipt(icon: .check, label: "Focus started: Report"))
        XCTAssertEqual(r("pause_focus", "ok: paused the focus session")?.label, "Focus paused")
        XCTAssertEqual(r("resume_focus", "ok: resumed the focus session")?.label, "Focus resumed")
        XCTAssertEqual(r("extend_focus", "ok: extended the session by 10m")?.label, "extended the session by 10m")
        XCTAssertEqual(r("cancel_focus", "ok: cancelled the focus session (nothing logged).")?.label, "Focus cancelled")
    }

    func testCaptureTools() {
        XCTAssertEqual(r("add_capture", "ok: captured id=c1 [idea] \"ask Sam\""),
                       Receipt(icon: .plus, label: "Captured: ask Sam", undo: .deleteCapture(id: "c1")))
        XCTAssertEqual(r("promote_capture", "ok: promoted capture to task id=t9 name=\"ask Sam\""),
                       Receipt(icon: .plus, label: "Task from capture: ask Sam", undo: .deleteTask(id: "t9")))
        XCTAssertEqual(r("resolve_capture", "ok: resolved capture \"ask Sam\"")?.label, "Resolved: ask Sam")
        XCTAssertEqual(r("delete_capture", "ok: deleted capture \"ask Sam\""), Receipt(icon: .pencil, label: "Deleted capture"))
    }

    func testListAreaTagAndSettingsToolsEchoTheResultMinusTheParenthetical() {
        XCTAssertEqual(r("rename_list", "ok: renamed list \"Groceries\" → \"Shopping\""),
                       Receipt(icon: .pencil, label: "renamed list \"Groceries\" → \"Shopping\""))
        XCTAssertEqual(r("archive_list", "ok: archived list \"Old\"")?.icon, .pencil)
        XCTAssertEqual(r("delete_list", "ok: deleted list \"Old\"")?.label, "deleted list \"Old\"")
        XCTAssertEqual(r("edit_list_item", "ok: edited item in \"Groceries\" → \"Oat milk\"")?.icon, .pencil)
        XCTAssertEqual(r("remove_list_item", "ok: removed \"Milk\" from \"Groceries\"")?.label, "removed \"Milk\" from \"Groceries\"")
        XCTAssertEqual(r("set_list_item_done", "ok: ticked \"Milk\" in \"Groceries\""),
                       Receipt(icon: .check, label: "ticked \"Milk\" in \"Groceries\""))
        XCTAssertEqual(r("create_area", "ok: created area \"Studio\""), Receipt(icon: .plus, label: "created area \"Studio\""))
        XCTAssertEqual(r("rename_area", "ok: renamed area \"Work\" → \"Studio\" (tasks updated)")?.label,
                       "renamed area \"Work\" → \"Studio\"")
        XCTAssertEqual(r("delete_area", "ok: deleted area \"Studio\" (its tasks keep everything else)")?.label, "deleted area \"Studio\"")
        XCTAssertEqual(r("create_tag", "ok: tag \"deep\" ready"), Receipt(icon: .plus, label: "tag \"deep\" ready"))
        XCTAssertEqual(r("rename_tag", "ok: renamed tag \"deep\" → \"focus\"")?.icon, .pencil)
        XCTAssertEqual(r("delete_tag", "ok: deleted tag \"deep\" (removed from tasks)")?.label, "deleted tag \"deep\"")
        XCTAssertEqual(r("unshare_task", "ok: stopped sharing \"Report\" with Sam")?.label, "stopped sharing \"Report\" with Sam")
        XCTAssertEqual(r("set_usable_minutes", "ok: usable time set — weekdays 240 min")?.label, "usable time set — weekdays 240 min")
        XCTAssertEqual(r("set_notification_level", "ok: notifications set to calm")?.icon, .pencil)
        XCTAssertEqual(r("set_reminder_lead", "ok: reminders 10 min before")?.label, "reminders 10 min before")
        XCTAssertEqual(r("set_ritual", "ok: morning moment on"), Receipt(icon: .pencil, label: "morning moment on"))
    }

    func testCallToolsPartB() {
        XCTAssertEqual(r("request_call", "ok: call booked 2026-09-03 14:45 \"speak to James\" (4 notes) id=cr1"),
                       Receipt(icon: .calendar, label: "Call booked Thu 14:45 — speak to James · 4 notes", undo: .cancelCall(id: "cr1")))
        XCTAssertEqual(r("request_call", "ok: call booked 2026-09-03 14:45 \"speak to James\" (1 note) id=cr1")?.label,
                       "Call booked Thu 14:45 — speak to James · 1 note")
        XCTAssertNil(r("request_call", "ok: booked"))
        XCTAssertEqual(r("update_call", "ok: updated call \"speak to James\" — 2026-09-04 09:00, 2 notes"),
                       Receipt(icon: .pencil, label: "Call updated Fri 09:00 — speak to James · 2 notes"))
        XCTAssertEqual(r("cancel_call", "ok: cancelled call \"speak to James\""),
                       Receipt(icon: .trash, label: "Call cancelled — speak to James"))
        XCTAssertNil(r("get_calls", "ok: 1 call"))
        XCTAssertEqual(planReceiptUndo(.cancelCall(id: "cr1"), tasks: [], nowISO: "n"), .cancelCall(id: "cr1"))
    }

    func testEveryWriteToolInTheContractYieldsAReceipt() {
        let writes = [
            "create_task", "schedule_task", "update_task", "set_task_later", "set_task_recurrence", "complete_task",
            "create_tasks", "complete_tasks", "delete_task", "create_list", "add_to_list", "promote_item_to_task",
            "save_profile_fact", "uncomplete_task", "unschedule_task", "skip_occurrence", "complete_occurrence",
            "block_time", "carry_to_tomorrow", "start_focus", "pause_focus", "resume_focus", "extend_focus",
            "cancel_focus", "add_capture", "promote_capture", "resolve_capture", "delete_capture", "rename_list",
            "archive_list", "delete_list", "edit_list_item", "remove_list_item", "set_list_item_done", "create_area",
            "rename_area", "delete_area", "create_tag", "rename_tag", "delete_tag", "unshare_task",
            "set_usable_minutes", "set_notification_level", "set_reminder_lead", "set_ritual", "forget_fact",
        ]
        for name in writes {
            XCTAssertNotNil(r(name, "ok: something \"X\" id=1"), "\(name) should produce a receipt")
        }
        XCTAssertEqual(writes.count, 46)
        // The 6 read/stage tools stay receipt-less: get_schedule, share_task, get_tasks, get_captures, get_insights, open_screen.
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

    func testBulkUndosPlanEveryPresentTask() {
        XCTAssertEqual(planReceiptUndo(.deleteTasks(ids: ["a", "b"]), tasks: [], nowISO: "n"), .deleteTasks(ids: ["a", "b"]))
        let a = task(id: "a", done: true, completedAt: "2026-08-02T10:00:00Z")
        let action = planReceiptUndo(.uncompleteTasks(ids: ["a", "gone"]), tasks: [a], nowISO: "2026-08-02T11:00:00Z")
        guard case .restoreTasks(let restored)? = action else { return XCTFail("expected restores") }
        XCTAssertEqual(restored.map { $0.id }, ["a"])
        XCTAssertFalse(restored[0].done)
        XCTAssertNil(planReceiptUndo(.uncompleteTasks(ids: ["gone"]), tasks: [], nowISO: "n"))
    }

    func testFactCaptureAndCompleteUndos() {
        XCTAssertEqual(planReceiptUndo(.forgetFact(id: "f1"), tasks: [], nowISO: "n"), .forgetFact(id: "f1"))
        XCTAssertEqual(planReceiptUndo(.deleteCapture(id: "c1"), tasks: [], nowISO: "n"), .deleteCapture(id: "c1"))
        let t = task(id: "t1")
        let action = planReceiptUndo(.completeTask(id: "t1"), tasks: [t], nowISO: "2026-08-02T11:00:00Z")
        guard case .completeTask(let done)? = action else { return XCTFail("expected a completion") }
        XCTAssertTrue(done.done)
        XCTAssertEqual(done.completedAt, "2026-08-02T11:00:00Z")
        XCTAssertEqual(done.updatedAt, "2026-08-02T11:00:00Z")
        XCTAssertNil(planReceiptUndo(.completeTask(id: "gone"), tasks: [], nowISO: "n"))
    }

    // MARK: repeating series (audit 2026-09-22, C3)

    /// complete_task on a series ticks TODAY's occurrence: complete_occurrence's
    /// card, no Undo — the name fallback would otherwise reopen an unrelated
    /// done task of the same name.
    func testCompleteTaskOnASeriesIsADoneForTodayCardWithNoUndo() {
        let sameName = task(id: "x", name: "Meds", done: true)
        let card = r("complete_task", "ok: marked \"Meds\" done for 2026-09-22 (series continues)", tasks: [sameName])
        XCTAssertEqual(card, Receipt(icon: .check, label: "Done for today: Meds"))
        XCTAssertNil(card?.undo)
        // A plain completion keeps its Undo.
        XCTAssertEqual(r("complete_task", "ok: completed \"X\" id=x", tasks: [sameName])?.undo, .uncompleteTask(id: "x"))
    }

    /// uncomplete_task on a series reopens TODAY's occurrence and carries no
    /// id=, so its card has no Undo (whose `.completeTask` would end the series).
    func testUncompleteOnASeriesHasNoUndo() {
        XCTAssertNil(r("uncomplete_task", "ok: reopened \"Meds\" for 2026-09-22 (series continues)")?.undo)
        XCTAssertNil(r("uncomplete_task", "ok: reopened \"Meds\" — its repeating series runs again")?.undo)
    }

    /// An older persisted "Reopened" receipt on a series' template never
    /// plans a completion of the template.
    func testCompleteUndoNeverTargetsASeriesTemplate() {
        var tpl = task(id: "tpl", name: "Meds")
        tpl.recurrence = .daily(until: nil)
        XCTAssertNil(planReceiptUndo(.completeTask(id: "tpl"), tasks: [tpl], nowISO: "n"))
    }

    func testReceiptsRoundTripThroughTheThreadPersistence() throws {
        let r = Receipt(icon: .check, label: "Completed “Report”", undo: .uncompleteTask(id: "x9"), undone: true)
        let back = try JSONDecoder().decode(Receipt.self, from: JSONEncoder().encode(r))
        XCTAssertEqual(back, r)
        XCTAssertFalse(back.isUndoable, "an already-used undo must not come back after a relaunch")
        for undo: ReceiptUndo in [.deleteTasks(ids: ["a"]), .uncompleteTasks(ids: ["a", "b"]), .forgetFact(id: "f"),
                                  .deleteCapture(id: "c"), .completeTask(id: "t")] {
            let rt = try JSONDecoder().decode(Receipt.self, from: JSONEncoder().encode(Receipt(icon: .plus, label: "x", undo: undo)))
            XCTAssertEqual(rt.undo, undo)
        }
    }
}
