import Foundation
import Testing

@testable import Automation

@Suite struct ScheduleTests {
    let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Berlin")!
        calendar.locale = Locale(identifier: "en_GB")
        return calendar
    }()

    func date(_ text: String) -> Date {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.date(from: text)!
    }

    let brief = AutomationTrigger.daily(hour: 7, minute: 30, weekdays: AutomationTrigger.weekdaysOnly)

    @Test func nextFireSkipsWeekends() {
        // Friday 2026-11-20 08:00 → Monday 2026-11-23 07:30.
        #expect(Schedule.nextFire(brief, after: date("2026-11-20 08:00"), calendar: calendar) == date("2026-11-23 07:30"))
        // Friday 07:00 → same day 07:30.
        #expect(Schedule.nextFire(brief, after: date("2026-11-20 07:00"), calendar: calendar) == date("2026-11-20 07:30"))
        // Exactly at the fire time → the next one, not the same.
        #expect(Schedule.nextFire(brief, after: date("2026-11-20 07:30"), calendar: calendar) == date("2026-11-23 07:30"))
    }

    @Test func dueOnceAfterMissedRuns() {
        // Last ran Monday 07:30; the Mac slept until Thursday 09:00 → due (once).
        #expect(Schedule.isDue(brief, lastRun: date("2026-11-16 07:30"), enabledAt: date("2026-11-01 00:00"), now: date("2026-11-19 09:00"), calendar: calendar))
        // After running Thursday 09:00 it's not due again until Friday 07:30.
        #expect(!Schedule.isDue(brief, lastRun: date("2026-11-19 09:00"), enabledAt: date("2026-11-01 00:00"), now: date("2026-11-20 07:29"), calendar: calendar))
        #expect(Schedule.isDue(brief, lastRun: date("2026-11-19 09:00"), enabledAt: date("2026-11-01 00:00"), now: date("2026-11-20 07:30"), calendar: calendar))
    }

    @Test func enablingDoesNotRunPastSlots() {
        // Enabled Friday 10:00 (after today's 07:30): nothing due until Monday.
        #expect(!Schedule.isDue(brief, lastRun: nil, enabledAt: date("2026-11-20 10:00"), now: date("2026-11-21 12:00"), calendar: calendar))
        #expect(Schedule.isDue(brief, lastRun: nil, enabledAt: date("2026-11-20 10:00"), now: date("2026-11-23 07:31"), calendar: calendar))
    }

    @Test func intervalAndWake() {
        let every15 = AutomationTrigger.interval(minutes: 15)
        #expect(!Schedule.isDue(every15, lastRun: date("2026-11-20 10:00"), enabledAt: date("2026-11-20 09:00"), now: date("2026-11-20 10:14"), calendar: calendar))
        #expect(Schedule.isDue(every15, lastRun: date("2026-11-20 10:00"), enabledAt: date("2026-11-20 09:00"), now: date("2026-11-20 10:15"), calendar: calendar))
        #expect(!Schedule.isDue(.onWake, lastRun: nil, enabledAt: date("2026-11-01 00:00"), now: date("2026-11-20 10:00"), calendar: calendar))
        #expect(Schedule.nextFire(.onWake, after: .now, calendar: calendar) == nil)
    }

    @Test func daylightSavingChange() {
        // Berlin switches to summer time on 2026-03-29 at 02:00 → 03:00; a 02:30 daily job runs at the next valid time.
        let night = AutomationTrigger.daily(hour: 2, minute: 30, weekdays: AutomationTrigger.everyDay)
        let next = Schedule.nextFire(night, after: date("2026-03-28 12:00"), calendar: calendar)!
        #expect(calendar.component(.day, from: next) == 29)
        #expect(calendar.component(.hour, from: next) == 3)
    }

    @Test func describesTriggers() {
        #expect(Schedule.describe(brief, calendar: calendar) == "Weekdays at 07:30")
        #expect(Schedule.describe(.daily(hour: 18, minute: 0, weekdays: [6, 2]), calendar: calendar) == "Mon, Fri at 18:00")
        #expect(Schedule.describe(.interval(minutes: 120), calendar: calendar) == "Every 2 h")
        #expect(Schedule.describe(.interval(minutes: 15), calendar: calendar) == "Every 15 min")
        #expect(Schedule.describe(.onWake, calendar: calendar) == "After waking")
    }

    @Test func triggersRoundTripThroughCodable() throws {
        for trigger in [brief, .interval(minutes: 5), .onWake] {
            let data = try JSONEncoder().encode(trigger)
            #expect(try JSONDecoder().decode(AutomationTrigger.self, from: data) == trigger)
        }
    }
}

@Suite struct AutomationStepsTests {
    @Test func oneStepPerLineWithoutCommentsOrBlanks() {
        let text = """
            # Morning routine
            /cleanup

              /digest
            # then the calendar
            What's on today, and which mails need a reply?
            """
        #expect(AutomationSteps.parse(text) == ["/cleanup", "/digest", "What's on today, and which mails need a reply?"])
        #expect(AutomationSteps.parse("/brief") == ["/brief"])
        #expect(AutomationSteps.parse("  \n# only a comment\n").isEmpty)
    }
}
