// Ported 1:1 from lib/assistant/polish.test.ts — the deterministic polish
// layer over the model's FINAL chat text. "before" texts marked (battery)
// are verbatim live replies from the naturalness diagnosis; "after" is what
// the deterministic layer can reach (the prose rewrites need the model).

import XCTest
@testable import UnstuckCore

final class ReplyPolishTests: XCTestCase {

    // Pinned "now" for the this-year rule (a Sunday in September 2026, UTC).
    private static let opts: PolishOptions = {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let now = cal.date(from: DateComponents(year: 2026, month: 9, day: 6, hour: 12))!
        return PolishOptions(now: now, calendar: cal)
    }()

    private func polish(_ s: String) -> String { polishReply(s, Self.opts) }

    // (name, before, after)
    private static let vectors: [(String, String, String)] = [
        // --- 1. openers
        ("battery 3: Done — dash", "Done — skipped gym for today.", "Skipped gym for today."),
        ("battery 4: Done — long", "Done — removed the dentist appointment from Thursday's schedule, but kept the task active.", "Removed the dentist appointment from Thursday's schedule, but kept the task active."),
        ("battery 9: Done — reminders", "Done — reminders set to 15 minutes before each task.", "Reminders set to 15 minutes before each task."),
        ("battery 1: capture (quoted name kept)", "Done — added capture \"ask Sam about the deck\" to Project check-in.", "Added capture \"ask Sam about the deck\" to Project check-in."),
        ("battery 10: blocked (quoted name kept)", "Done — blocked \"School play\" for 1 hour tomorrow at 6pm.", "Blocked \"School play\" for 1 hour tomorrow at 6pm."),
        ("battery 8: opener before a quote — no capitalising inside the quote", "Done — \"Milk\" is now checked off your Groceries list.", "\"Milk\" is now checked off your Groceries list."),
        ("Done. full stop", "Done. Moved the report to Friday.", "Moved the report to Friday."),
        ("Sure thing —", "Sure thing — booked it.", "Booked it."),
        ("case-insensitive opener with comma", "okay, moved it to 4pm.", "Moved it to 4pm."),
        ("stacked openers", "Sure — done — moved it.", "Moved it."),
        ("Got it. with a question", "Got it. Who's Maleek?", "Who's Maleek?"),
        ("\"Great question\" is not an opener", "Great question — the report is Friday.", "Great question — the report is Friday."),
        // --- 2. closers
        ("battery 7: opener + generic closer", "Done — your week is open. Let me know if you'd like help adjusting anything on it!", "Your week is open."),
        ("battery 11: closer without a weekday", "Done — set to 4 hours on weekdays. Let me know if you'd like to adjust weekend time too.", "Set to 4 hours on weekdays."),
        ("battery 5: multi-item list kept, closer dropped", "Your backlog has two tasks:\n\n- Project check-in (30 minutes, Work)\n- Write the report (50 minutes, Work)\n\nLet me know if you'd like to schedule either of these or move them into active work!", "Your backlog has two tasks:\n\n- Project check-in (30 minutes, Work)\n- Write the report (50 minutes, Work)"),
        ("generic \"Anything else?\" dropped", "Moved it to 4pm. Anything else?", "Moved it to 4pm."),
        ("\"Hope that helps!\" dropped", "The report is Friday at 2pm. Hope that helps!", "The report is Friday at 2pm."),
        ("closer-only reply stays", "Let me know if you need anything else!", "Let me know if you need anything else!"),
        ("specific offer with a weekday kept", "Moved it to 4pm. Want me to move the report to tomorrow?", "Moved it to 4pm. Want me to move the report to tomorrow?"),
        ("specific offer with a real object kept", "Two things — the project check-in and the report. Want either on the calendar?", "Two things — the project check-in and the report. Want either on the calendar?"),
        ("closer naming a quoted task kept", "Booked Thursday. Let me know if \"Report\" should move too.", "Booked Thursday. Let me know if \"Report\" should move too."),
        ("two stacked closers both dropped", "Booked Thursday 2pm. Feel free to change it. Hope this helps!", "Booked Thursday 2pm."),
        // --- 3. exclamation restraint
        ("battery 2: confirmation cheer", "Focus session started on \"Write the report\" for 50 minutes — you're all set!", "Focus session started on \"Write the report\" for 50 minutes — you're all set."),
        ("greeting keeps its \"!\", confirmation loses it", "Hey Maya! Added the report for tomorrow!", "Hey Maya! Added the report for tomorrow."),
        ("no confirmation verb → \"!\" stays", "Happy birthday!", "Happy birthday!"),
        ("\"!\" inside quotes untouched", "Added \"Call mum!\" for tonight!", "Added \"Call mum!\" for tonight."),
        // --- 4. dates and times
        ("voice bonus: ISO date + 24h time", "Done — scheduled Dentist on 2026-09-04 at 14:00.", "Scheduled Dentist on Fri 4 Sep at 2pm."),
        ("half hour, midnight, noon, leading zero", "Slots: 14:30, 00:30, 12:00 and 09:05.", "Slots: 2:30pm, 12:30am, 12pm and 9:05am."),
        ("other year keeps the year", "Booked for 2027-01-03.", "Booked for Sun 3 Jan 2027."),
        ("time range", "Blocked 14:00-15:00 tomorrow.", "Blocked 2pm-3pm tomorrow."),
        ("invalid date, 1-digit hour, explicit pm, seconds untouched", "Not 2026-13-45, nor 9:05, nor 10:30 pm, nor 14:00:00.", "Not 2026-13-45, nor 9:05, nor 10:30 pm, nor 14:00:00."),
        ("id= token protected, prose converted", "Created task id=2026-09-05-14:00 for 2026-09-05 at 14:00.", "Created task id=2026-09-05-14:00 for Sat 5 Sep at 2pm."),
        ("URL protected", "See https://unstucknow.io/t/2026-09-05?at=14:00 — booked for 2026-09-05.", "See https://unstucknow.io/t/2026-09-05?at=14:00 — booked for Sat 5 Sep."),
        ("backticks and quotes protected", "Renamed `2026-09-05 14:00` to \"Done — 2026-09-05 14:00\".", "Renamed `2026-09-05 14:00` to \"Done — 2026-09-05 14:00\"."),
        ("ISO datetime is not a standalone token", "Synced at 2026-09-05T14:00:00Z.", "Synced at 2026-09-05T14:00:00Z."),
        // --- 5. markdown residue
        ("bold collapsed", "**Milk** is ticked off.", "Milk is ticked off."),
        ("single-item bullet becomes a sentence", "One thing in your backlog:\n- Write the report (50 min)", "One thing in your backlog: Write the report (50 min)."),
        ("multi-item list untouched", "Today:\n- Gym at 4pm\n- Dentist at 5pm", "Today:\n- Gym at 4pm\n- Dentist at 5pm"),
        // --- 6. whitespace
        ("doubled spaces collapsed, trimmed", "  Booked  it  for Friday.  ", "Booked it for Friday."),
        // --- unchanged / guards
        ("battery 12: destructive confirmation untouched", "I'll help you delete your Health area. Before I do that, I need to confirm this action since it will remove the area but keep all tasks associated with it.\n\nAre you sure you want to delete the Health area?", "I'll help you delete your Health area. Before I do that, I need to confirm this action since it will remove the area but keep all tasks associated with it.\n\nAre you sure you want to delete the Health area?"),
        ("battery 6: insights read-back untouched", "You focused for 3h 20m across 5 sessions this week — median session was 40 minutes. You hit your estimates 60% of the time.", "You focused for 3h 20m across 5 sessions this week — median session was 40 minutes. You hit your estimates 60% of the time."),
        ("empty-guard: \"Done.\" alone stays", "Done.", "Done."),
        ("empty-guard: \"Done —\" alone stays", "Done —", "Done —"),
        ("error reply untouched", "Sorry — that didn't go through. Which day?", "Sorry — that didn't go through. Which day?"),
    ]

    func testEveryVector() {
        for (name, before, after) in Self.vectors {
            XCTAssertEqual(polish(before), after, name)
        }
    }

    func testIdempotentOnEveryVector() {
        for (name, before, _) in Self.vectors {
            let once = polish(before)
            XCTAssertEqual(polish(once), once, "idempotence: \(name)")
        }
    }

    func testNeverProducesAnEmptyString() {
        XCTAssertEqual(polish(""), "")
        XCTAssertEqual(polish("   "), "   ")
        XCTAssertEqual(polish("Sure!"), "Sure!")
        XCTAssertEqual(polish("Okay —  "), "Okay —")
    }

    func testDefaultsNowToTheCurrentYear() {
        let y = Calendar.current.component(.year, from: Date())
        XCTAssertFalse(polishReply("Booked for \(y)-03-01.").contains(String(y)))
    }

    func testSpokenDateAndTimeHelpers() {
        XCTAssertEqual(spokenDate(year: 2026, month: 9, day: 5, thisYear: 2026), "Sat 5 Sep")
        XCTAssertEqual(spokenDate(year: 2024, month: 2, day: 29, thisYear: 2026), "Thu 29 Feb 2024")
        XCTAssertNil(spokenDate(year: 2026, month: 2, day: 29, thisYear: 2026))
        XCTAssertEqual(spokenTime(hour: 0, minute: 0), "12am")
        XCTAssertEqual(spokenTime(hour: 12, minute: 0), "12pm")
        XCTAssertEqual(spokenTime(hour: 23, minute: 59), "11:59pm")
    }

    /// With the device clock (what the app passes), a raw 14:30 from a tool
    /// result reads in the user's own 12/24-hour clock — a 24-hour phone keeps
    /// "14:30", a 12-hour one gets the app's "2:30 PM" (2026-09-24).
    func testTimesFollowTheDeviceClockWhenGiven() {
        func polished(_ s: String, _ clock: ClockFormat) -> String {
            var o = Self.opts
            o.clock = clock
            return polishReply(s, o)
        }
        let before = "Done — scheduled Dentist on 2026-09-04 at 14:00. Slots: 14:30, 00:30 and 09:05."
        XCTAssertEqual(polished(before, .h24), "Scheduled Dentist on Fri 4 Sep at 14:00. Slots: 14:30, 00:30 and 09:05.")
        XCTAssertEqual(polished(before, .h12), "Scheduled Dentist on Fri 4 Sep at 2 PM. Slots: 2:30 PM, 12:30 AM and 9:05 AM.")
        XCTAssertEqual(polished("Blocked 14:00-15:00 tomorrow.", .h12), "Blocked 2 PM-3 PM tomorrow.")
        // Idempotent in both modes; protected spans still untouched.
        for clock in [ClockFormat.h12, .h24] {
            let once = polished(before, clock)
            XCTAssertEqual(polished(once, clock), once)
            XCTAssertEqual(polished("Renamed `14:00` to \"14:00\".", clock), "Renamed `14:00` to \"14:00\".")
        }
        // No clock → the web's spoken vectors, unchanged.
        XCTAssertEqual(polish("Moved it to 14:30."), "Moved it to 2:30pm.")
    }

    func testVectorCountCoversTheContract() {
        XCTAssertGreaterThanOrEqual(Self.vectors.count, 25)
    }
}
