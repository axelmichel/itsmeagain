import Foundation
import Testing

@testable import PersonalData

@Suite struct MonthGridTests {
    func calendar(firstWeekday: Int) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Berlin")!
        calendar.firstWeekday = firstWeekday
        calendar.locale = Locale(identifier: "en_US")
        return calendar
    }

    @Test func mondayFirstNovember2026() {
        let calendar = calendar(firstWeekday: 2)
        let grid = MonthGrid(containing: calendar.date(from: DateComponents(year: 2026, month: 11, day: 21))!, calendar: calendar)
        // 1 Nov 2026 is a Sunday → six empty cells before it in a Monday-first grid.
        #expect(grid.weekdaySymbols == ["M", "T", "W", "T", "F", "S", "S"])
        #expect(grid.weeks.first?.prefix(6).allSatisfy { $0 == nil } == true)
        #expect(grid.weeks.first?[6].map { calendar.component(.day, from: $0) } == 1)
        #expect(grid.weeks.count == 6)
        #expect(grid.weeks.flatMap { $0 }.compactMap { $0 }.count == 30)
        #expect(grid.weeks.allSatisfy { $0.count == 7 })
    }

    @Test func sundayFirstFebruary2026FitsFourRows() {
        let calendar = calendar(firstWeekday: 1)
        let grid = MonthGrid(containing: calendar.date(from: DateComponents(year: 2026, month: 2, day: 10))!, calendar: calendar)
        // 1 Feb 2026 is a Sunday: 28 days fill exactly four weeks.
        #expect(grid.weeks.count == 4)
        #expect(grid.weekdaySymbols.first == "S")
    }
}

@Suite struct DayParserTests {
    static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Berlin")!
        return calendar
    }
    static let now = calendar.date(from: DateComponents(year: 2026, month: 11, day: 21, hour: 15))!

    @Test(arguments: [
        ("24.12.", "2026-12-24"),
        ("24.12", "2026-12-24"),
        ("3.2.", "2027-02-03"),
        ("24.12.2027", "2027-12-24"),
        ("1.1.27", "2027-01-01"),
        ("Dezember", "2026-12-01"),
        ("december", "2026-12-01"),
        ("November", "2026-11-21"),
        ("März", "2027-03-01"),
        ("march 2028", "2028-03-01"),
        ("2026-12", "2026-12-01"),
        ("12/2026", "2026-12-01"),
        ("24 Dec", "2026-12-24"),
        ("dec 24", "2026-12-24"),
        ("2026-12-24", "2026-12-24"),
        ("tomorrow", "2026-11-22"),
    ])
    func parses(text: String, expected: String) throws {
        let date = try #require(DayParser.parse(text, now: Self.now, calendar: Self.calendar))
        let formatter = DateFormatter()
        formatter.calendar = Self.calendar
        formatter.timeZone = Self.calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        #expect(formatter.string(from: date) == expected)
    }

    @Test func rejectsImpossibleDates() {
        #expect(DayParser.parse("31.2.", now: Self.now, calendar: Self.calendar) == nil)
        #expect(DayParser.parse("13.13.", now: Self.now, calendar: Self.calendar) == nil)
    }
}
