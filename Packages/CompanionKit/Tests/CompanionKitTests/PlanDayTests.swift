import Foundation
import Testing

@testable import PersonalData

@Suite struct PlanDayTests {
    var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Berlin")!
        return calendar
    }
    var now: Date { calendar.date(from: DateComponents(year: 2026, month: 11, day: 21, hour: 9))! }

    func time(_ item: PlanItem) -> String? {
        item.at.map { String(format: "%02d:%02d", calendar.component(.hour, from: $0), calendar.component(.minute, from: $0)) }
    }
    func day(_ item: PlanItem) -> Int { calendar.component(.day, from: item.day) }

    @Test func parsesTheList() {
        let items = PlanDayParser.parse("""
            - Task 1,
            - Task 2 ...
            * 14:00 Call Tom
            • Zahnarzt um 9.30 Uhr
            1. Pick up parcel at 5pm
            - [ ] Write report 16 Uhr

            morgen: Bäcker 7:15
            tomorrow - Send invoice
            """, now: now, calendar: calendar)
        #expect(items.map(\.title) == ["Task 1", "Task 2 ...", "Call Tom", "Zahnarzt", "Pick up parcel", "Write report", "Bäcker", "Send invoice"])
        #expect(items.map(time) == [nil, nil, "14:00", "09:30", "17:00", "16:00", "07:15", nil])
        #expect(items.map(day) == [21, 21, 21, 21, 21, 21, 22, 22])
    }

    @Test func numbersThatArentTimesStay() {
        let items = PlanDayParser.parse("- Order 25 screws\n- Read chapter 3.2", now: now, calendar: calendar)
        #expect(items.map(\.title) == ["Order 25 screws", "Read chapter 3.2"])
        #expect(items.allSatisfy { $0.at == nil })
    }
}
