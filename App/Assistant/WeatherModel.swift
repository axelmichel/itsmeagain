import Foundation
import Observation
import Weather

/// Weather for one place you choose (Open-Meteo; only that place's coordinates are sent).
@MainActor
@Observable
final class WeatherModel {
    static let refreshAfter: TimeInterval = 30 * 60

    private(set) var place: WeatherPlace? = UserDefaults.standard.data(forKey: "weatherPlace")
        .flatMap { try? JSONDecoder().decode(WeatherPlace.self, from: $0) } {
        didSet { UserDefaults.standard.set(try? JSONEncoder().encode(place), forKey: "weatherPlace") }
    }
    private(set) var report: WeatherReport?
    private(set) var error: String?
    private(set) var isLoading = false
    @ObservationIgnored private let client = OpenMeteo()

    func search(_ name: String) async throws -> [WeatherPlace] {
        try await client.places(matching: name, language: Locale.current.language.languageCode?.identifier ?? "en")
    }

    func choose(_ place: WeatherPlace?) {
        self.place = place
        report = nil
        Task { await refresh(force: true) }
    }

    func refresh(force: Bool = false) async {
        guard let place, !isLoading else { return }
        if !force, let report, report.place == place, Date.now.timeIntervalSince(report.fetched) < Self.refreshAfter { return }
        isLoading = true
        defer { isLoading = false }
        do {
            report = try await client.report(for: place)
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// For /weather.
    var markdown: String {
        guard let report else { return error.map { "Weather isn't available: \($0)" } ?? "No weather yet." }
        let hours = report.hours.prefix(8).map { hour in
            "\(hour.time.formatted(.dateTime.hour(.twoDigits(amPM: .omitted)))) \(Int(hour.temperature.rounded()))°" + (hour.precipitationChance >= 30 ? " (\(hour.precipitationChance)% rain)" : "")
        }.joined(separator: " · ")
        return """
            **\(report.place.name): \(Int(report.temperature.rounded()))°, \(WeatherCode.text(report.code))** (feels like \(Int(report.feelsLike.rounded()))°, wind \(Int(report.wind.rounded())) km/h)
            Today \(Int(report.low.rounded()))°–\(Int(report.high.rounded()))°, rain chance \(report.precipitationChance)%
            Next hours: \(hours)
            """
    }
}
