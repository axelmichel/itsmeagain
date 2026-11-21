import CompanionCore
import Foundation
import Testing

@testable import Mail

@Suite struct AppointmentTests {
    static let mail = MailMessage(id: "<inv@x>", account: "A", sender: "Tom Weber <tom@company.de>", subject: "Einladung: Budget", date: .now, isRead: false)

    @Test func invitationFromICSPart() throws {
        let ics = """
            BEGIN:VCALENDAR\r
            METHOD:REQUEST\r
            BEGIN:VEVENT\r
            DTSTART;TZID=Europe/Berlin:20261124T140000\r
            DTEND;TZID=Europe/Berlin:20261124T153000\r
            SUMMARY:Budget Q1\\, Planung\r
            LOCATION:Raum 4\r
             .12\r
            END:VEVENT\r
            END:VCALENDAR\r
            """
        let raw = "Content-Type: multipart/mixed; boundary=\"b\"\n\n--b\nContent-Type: text/plain\n\nSee invite\n--b\nContent-Type: text/calendar; method=REQUEST\nContent-Transfer-Encoding: base64\n\n\(Data(ics.utf8).base64EncodedString())\n--b--"
        let parsed = MIMEParser.parse(raw)
        let now = Date(timeIntervalSince1970: 1_795_000_000)  // Nov 2026
        let found = AppointmentFinder.invitations(parsed, mail: Self.mail, now: now)
        let event = try #require(found.first)
        #expect(event.title == "Budget Q1, Planung")
        #expect(event.location == "Raum 4.12")
        #expect(event.origin == .invitation)
        var berlin = Calendar(identifier: .gregorian)
        berlin.timeZone = TimeZone(identifier: "Europe/Berlin")!
        #expect(berlin.component(.hour, from: event.start) == 14)
        #expect(event.end.timeIntervalSince(event.start) == 90 * 60)
    }

    @Test func cancellationsAllDayAndPastAreSkipped() {
        let now = Date(timeIntervalSince1970: 1_795_000_000)
        let cancel = "BEGIN:VCALENDAR\nMETHOD:CANCEL\nBEGIN:VEVENT\nDTSTART:20271124T140000Z\nSUMMARY:X\nEND:VEVENT\nEND:VCALENDAR"
        #expect(AppointmentFinder.invitations(ParsedMail(headers: [:], calendar: cancel), mail: Self.mail, now: now).isEmpty)
        let past = "BEGIN:VCALENDAR\nBEGIN:VEVENT\nDTSTART:20200101T100000Z\nSUMMARY:Old\nEND:VEVENT\nEND:VCALENDAR"
        #expect(AppointmentFinder.invitations(ParsedMail(headers: [:], calendar: past), mail: Self.mail, now: now).isEmpty)
        let allDay = "BEGIN:VCALENDAR\nBEGIN:VEVENT\nDTSTART;VALUE=DATE:20261201\nDURATION:P1D\nSUMMARY:Offsite\nEND:VEVENT\nEND:VCALENDAR"
        let found = AppointmentFinder.invitations(ParsedMail(headers: [:], calendar: allDay), mail: Self.mail, now: now)
        #expect(found.first?.isAllDay == true && found.first?.end.timeIntervalSince(found.first!.start) == 86_400)
    }

    @Test func textExtractionValidatesDates() async throws {
        let now = Date(timeIntervalSince1970: 1_795_000_000)
        let reply = #"{"appointments":[{"title":"Zahnarzt Dr. Müller","start":"2027-01-12T09:30","end":"","all_day":false,"location":"Hauptstr. 5"},{"title":"Old","start":"2020-01-01T10:00","end":"","all_day":false,"location":""},{"title":"Bad","start":"soon","end":"","all_day":false,"location":""}]}"#
        let found = try await AppointmentFinder.extract(
            text: "Ihr Termin am 12.01. um 9:30", mail: Self.mail, provider: ScriptedProvider(reply: reply), model: "m", now: now)
        #expect(found.map(\.title) == ["Zahnarzt Dr. Müller"])
        #expect(found[0].end.timeIntervalSince(found[0].start) == 3_600, "one hour when no end is given")
        #expect(found[0].location == "Hauptstr. 5" && found[0].origin == .text)
    }

    @Test func preFilter() {
        #expect(AppointmentFinder.mightContainAppointment(subject: "Ihr Termin", text: ""))
        #expect(AppointmentFinder.mightContainAppointment(subject: "Re: Freitag", text: "Passt dir 14:30?"))
        #expect(!AppointmentFinder.mightContainAppointment(subject: "Your invoice", text: "Thanks for your purchase."))
        #expect(AppointmentFinder.mightContainAppointment(subject: "Kurze Frage", text: "Können wir uns am Dienstag sehen?"))
        #expect(AppointmentFinder.mightContainAppointment(subject: "Ihre Buchung", text: "am 24.11. in Berlin"))
        #expect(AppointmentFinder.mightContainAppointment(subject: "Visit", text: "See you November 24"))
    }

    @Test func importantSendersGroupedByAddress() {
        let preferences = MailPreferences(vipSenders: ["tom@company.de", "Anna"])
        let messages = [
            MailMessage(id: "1", account: "A", sender: "Tom Weber <tom@company.de>", subject: "Budget", date: .now, isRead: false),
            MailMessage(id: "2", account: "A", sender: "Tom Weber <tom@company.de>", subject: "Budget v2", date: .now.addingTimeInterval(60), isRead: false),
            MailMessage(id: "3", account: "A", sender: "Anna <anna@example.org>", subject: "Lunch", date: .now, isRead: false),
            MailMessage(id: "4", account: "A", sender: "Anna <anna@example.org>", subject: "Read already", date: .now, isRead: true),
            MailMessage(id: "5", account: "A", sender: "Shop <info@shop.example>", subject: "Sale", date: .now, isRead: false),
        ]
        let groups = MailWatch.fromImportant(messages, preferences: preferences, seen: ["3"])
        #expect(groups.map(\.address) == ["tom@company.de"])
        #expect(groups[0].messages.map(\.subject) == ["Budget v2", "Budget"])
        #expect(MailWatch.notificationBody(groups[0].messages) == "Budget v2 · Budget")
    }
}

/// Made-up mails through the local model. `OLLAMA_LIVE=1 swift test --filter AppointmentLiveTests`
@Suite(.enabled(if: ProcessInfo.processInfo.environment["OLLAMA_LIVE"] == "1"))
struct AppointmentLiveTests {
    func mail(_ subject: String, from: String = "Praxis Dr. Müller <info@praxis.example>") -> MailMessage {
        MailMessage(id: UUID().uuidString, account: "A", sender: from, subject: subject, date: .now, isRead: false)
    }

    @Test func findsRealAppointmentsOnly() async throws {
        let provider = OllamaProviderForTests.make()
        let cases: [(String, String, Bool)] = [
            ("Terminbestätigung", "Guten Tag, hiermit bestätigen wir Ihren Termin am kommenden Dienstag um 9:30 Uhr in unserer Praxis, Hauptstraße 5. Bitte bringen Sie Ihre Versichertenkarte mit.", true),
            ("Re: Abstimmung Budget", "Hi, passt dir Donnerstag 14 Uhr für eine halbe Stunde? Ich schicke dann einen Teams-Link. Gruß, Tom", true),
            ("Webinar: AI for everyone", "Join 10,000 others on our free webinar every Wednesday at 18:00 CET! Sign up now and get 20% off.", false),
            ("Ihre Lieferung kommt morgen", "Ihr Paket wird morgen zwischen 10:00 und 14:00 Uhr zugestellt.", false),
            ("Reminder: submit your report", "Please submit the Q4 report by Friday 17:00.", false),
        ]
        for (subject, text, expected) in cases {
            let started = ContinuousClock.now
            let found = try await AppointmentFinder.extract(text: text, mail: mail(subject), provider: provider, model: "gemma4:26b")
            let summary = found.map { "\($0.title) @ \($0.start.formatted(date: .abbreviated, time: .shortened))\($0.location.map { " – \($0)" } ?? "")" }
            print("APPOINTMENT LIVE: \(expected ? "expect" : "no    ") \(subject): \(found.count) in \(ContinuousClock.now - started) \(summary)")
            #expect(found.isEmpty != expected, "\(subject)")
        }
    }
}

/// Real unread mail, read-only; prints counts and timings only. `MAIL_LIVE=1 swift test --filter AppointmentMailLiveTests`
@Suite(.enabled(if: ProcessInfo.processInfo.environment["MAIL_LIVE"] == "1"))
struct AppointmentMailLiveTests {
    @Test func scanRealUnreadMail() async throws {
        let source = AppleMailSource()
        let provider = OllamaProviderForTests.make()
        var started = ContinuousClock.now
        let messages = try await source.recent(days: 7, unreadOnly: true, limit: 200)
        print("APPT MAIL LIVE: \(messages.count) unread (7 days) listed in \(ContinuousClock.now - started)")
        started = ContinuousClock.now
        var invitations = 0, candidates = 0, proposals = 0, read = 0
        for start in stride(from: 0, to: messages.count, by: 10) {
            let batch = Array(messages[start..<min(start + 10, messages.count)])
            let sources = try await source.sources(ids: batch.map(\.id))
            for message in batch {
                guard let raw = sources[message.id] else { continue }
                read += 1
                let parsed = MIMEParser.parse(raw)
                let invites = AppointmentFinder.invitations(parsed, mail: message)
                invitations += invites.count
                if invites.isEmpty, AppointmentFinder.mightContainAppointment(subject: message.subject, text: parsed.readableText) {
                    candidates += 1
                    proposals += (try? await AppointmentFinder.extract(text: parsed.readableText, mail: message, provider: provider, model: "gemma4:26b"))?.count ?? 0
                }
            }
        }
        print("APPT MAIL LIVE: read \(read) mails in \(ContinuousClock.now - started): \(invitations) invitations, \(candidates) pass the pre-filter, model found \(proposals) appointments in them")
    }
}
