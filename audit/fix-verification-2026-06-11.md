All 20 verdicts are in the provided JSON with full reasoning; no file inspection is needed to compile the report.

# iOS Bug-Fix Verification — 20 fixes

**19 / 20 fixed-clean. 1 needs attention** (medium, fixed-with-regression).

## Needs attention

**Today list drops completed-today tasks and occurrences instead of keeping them as struck-through wins**
- File: `/Users/ahmadtambaya/Desktop/projects/unstuck_ios/App/Features/TodayFeature.swift`
- Status: **fixed-with-regression** (medium)
- What's wrong: List inclusion is fixed (completed-today tasks/occurrences now appear via `TodayModel.rows` lines 85-86), but the rendering half is missing. `taskRow` (lines 313-346) applies no visual distinction to done tasks — no strikethrough, no gray (`ink3`) text, no green checkmark. Completed rows now look identical to open ones and don't toggle on tap, which is arguably more confusing than the original drop-them behavior. Audit ref: `audit/parity-bug-sweep-2026-06-11.md` lines 50-54.
- What to do (in `taskRow`):
  1. Strikethrough + gray the name (line 319): `Text(t.name).font(UFont.sans(16, .medium)).strikethrough(t.done).foregroundStyle(t.done ? theme.palette.ink3 : theme.palette.ink).lineLimit(1)`
  2. Add a leading green checkmark for `t.done` rows (mirror `TasksFeature.swift:71` / Android `TodayScreen.kt:277-282`).
  3. Optionally gray the estimate text to `ink3` when done for consistency.

## Verified clean

- scheduleTaskAt recurrence branch can leave the chosen date with NO block (coversChosen ignores plan.toDelete) — **high**
- Start-Next hero task duplicated in Today list / focused task not excluded from suggestion — **medium**
- OutboxFlusher.flush has no drain serialization — concurrent drains interleave via actor reentrancy — **high**
- Cancelled drain mis-counted as op failure, burns the poison-pill cap — **high**
- Inbox "Open" fails to present the task: dismiss + present two sheets in one runloop tick — **high**
- Capture tag badge renders lowercase on iOS vs uppercase on Android — **medium**
- promoteCapture writes the new task twice (lifeArea=nil then "Work") — **low**
- PKCE forgot-password link logs straight into app — set-new-password screen never shows — **critical**
- First task's firstPhysicalAction can be lost via a double unordered write race — **high**
- Onboarding first task not tagged with the user's life area — **medium**
- Onboarding first-task estimate differs from Android (25 vs 15 min) — **low**
- STT engine.start() failure leaks the installed tap → next dictation crashes AVAudioEngine — **high**
- Per-session URLSession never invalidated — leaks an operation queue per voice call — **medium**
- onOpen() fired eagerly before WebSocket handshake completes — **medium**
- flushPlayback() clears the capture accumulation buffer — barge-in drops mic audio — **low**
- VoiceController.request/task mutated off-lock in begin() while stopListening() reads under lock — **low**
- Inbox/Notification deep-link opens nothing: dismiss() + set detailTask in same tick — **high**
- Feedback/Assistant bubble shows on the Calendar tab (Android hides it there) — **medium**
- Device-local personal content not scrubbed on a non-button sign-out — cross-account leak — **medium**