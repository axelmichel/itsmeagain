import Foundation

/// A place the weather is for (from Open-Meteo's geocoding).
public struct WeatherPlace: Codable, Sendable, Hashable {
    public var name: String
    public var country: String
    public var latitude: Double
    public var longitude: Double

    public init(name: String, country: String, latitude: Double, longitude: Double) {
        self.name = name
        self.country = country
        self.latitude = latitude
        self.longitude = longitude
    }
}

public struct WeatherReport: Codable, Sendable, Hashable {
    public struct Hour: Codable, Sendable, Hashable {
        public var time: Date
        public var temperature: Double
        public var code: Int
        public var precipitationChance: Int
    }

    public var place: WeatherPlace
    public var fetched: Date
    public var temperature: Double
    public var feelsLike: Double
    public var code: Int
    public var wind: Double
    public var isDay: Bool
    public var high: Double
    public var low: Double
    public var precipitationChance: Int
    public var hours: [Hour]
}

/// Open-Meteo: free, no account or key (non-commercial use). Only the place's coordinates are sent.
public struct OpenMeteo: Sendable {
    let session: URLSession
    let geocodingBase: URL
    let forecastBase: URL

    public init(
        session: URLSession = .shared,
        geocodingBase: URL = URL(string: "https://geocoding-api.open-meteo.com")!,
        forecastBase: URL = URL(string: "https://api.open-meteo.com")!
    ) {
        self.session = session
        self.geocodingBase = geocodingBase
        self.forecastBase = forecastBase
    }

    public func places(matching name: String, language: String = "en") async throws -> [WeatherPlace] {
        var components = URLComponents(url: geocodingBase.appending(path: "v1/search"), resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "name", value: name), URLQueryItem(name: "count", value: "5"),
            URLQueryItem(name: "language", value: language), URLQueryItem(name: "format", value: "json"),
        ]
        struct Response: Decodable {
            struct Result: Decodable {
                var name: String
                var country: String?
                var latitude: Double
                var longitude: Double
            }
            var results: [Result]?
        }
        let response = try JSONDecoder().decode(Response.self, from: try await get(components.url!))
        return (response.results ?? []).map { WeatherPlace(name: $0.name, country: $0.country ?? "", latitude: $0.latitude, longitude: $0.longitude) }
    }

    public func report(for place: WeatherPlace, now: Date = .now) async throws -> WeatherReport {
        var components = URLComponents(url: forecastBase.appending(path: "v1/forecast"), resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "latitude", value: String(format: "%.4f", place.latitude)),
            URLQueryItem(name: "longitude", value: String(format: "%.4f", place.longitude)),
            URLQueryItem(name: "current", value: "temperature_2m,apparent_temperature,weather_code,wind_speed_10m,is_day"),
            URLQueryItem(name: "hourly", value: "temperature_2m,weather_code,precipitation_probability"),
            URLQueryItem(name: "daily", value: "temperature_2m_max,temperature_2m_min,precipitation_probability_max"),
            URLQueryItem(name: "timezone", value: "auto"),
            URLQueryItem(name: "forecast_days", value: "2"),
            URLQueryItem(name: "timeformat", value: "unixtime"),
        ]
        return try Self.parse(try await get(components.url!), place: place, now: now)
    }

    static func parse(_ data: Data, place: WeatherPlace, now: Date) throws -> WeatherReport {
        struct Response: Decodable {
            struct Current: Decodable {
                var temperature_2m: Double
                var apparent_temperature: Double
                var weather_code: Int
                var wind_speed_10m: Double
                var is_day: Int
            }
            struct Hourly: Decodable {
                var time: [TimeInterval]
                var temperature_2m: [Double]
                var weather_code: [Int]
                var precipitation_probability: [Int?]
            }
            struct Daily: Decodable {
                var temperature_2m_max: [Double]
                var temperature_2m_min: [Double]
                var precipitation_probability_max: [Int?]
            }
            var current: Current
            var hourly: Hourly
            var daily: Daily
        }
        let response = try JSONDecoder().decode(Response.self, from: data)
        let hourly = response.hourly
        let hours = hourly.time.indices.compactMap { index -> WeatherReport.Hour? in
            let time = Date(timeIntervalSince1970: hourly.time[index])
            guard time >= now.addingTimeInterval(-1_800), index < hourly.temperature_2m.count, index < hourly.weather_code.count else { return nil }
            return WeatherReport.Hour(
                time: time, temperature: hourly.temperature_2m[index], code: hourly.weather_code[index],
                precipitationChance: index < hourly.precipitation_probability.count ? hourly.precipitation_probability[index] ?? 0 : 0
            )
        }
        return WeatherReport(
            place: place, fetched: now,
            temperature: response.current.temperature_2m, feelsLike: response.current.apparent_temperature,
            code: response.current.weather_code, wind: response.current.wind_speed_10m, isDay: response.current.is_day == 1,
            high: response.daily.temperature_2m_max.first ?? response.current.temperature_2m,
            low: response.daily.temperature_2m_min.first ?? response.current.temperature_2m,
            precipitationChance: response.daily.precipitation_probability_max.first.flatMap { $0 } ?? 0,
            hours: Array(hours.prefix(12))
        )
    }

    private func get(_ url: URL) async throws -> Data {
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.setValue("ItsMeAgain/1.0", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse, userInfo: [NSLocalizedDescriptionKey: "The weather service answered HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)."])
        }
        return data
    }
}

/// WMO weather codes → words and SF Symbols.
public enum WeatherCode {
    public static func text(_ code: Int) -> String {
        switch code {
        case 0: "Clear"
        case 1: "Mostly clear"
        case 2: "Partly cloudy"
        case 3: "Overcast"
        case 45, 48: "Fog"
        case 51, 53, 55: "Drizzle"
        case 56, 57: "Freezing drizzle"
        case 61: "Light rain"
        case 63: "Rain"
        case 65: "Heavy rain"
        case 66, 67: "Freezing rain"
        case 71: "Light snow"
        case 73: "Snow"
        case 75: "Heavy snow"
        case 77: "Snow grains"
        case 80, 81, 82: "Showers"
        case 85, 86: "Snow showers"
        case 95: "Thunderstorm"
        case 96, 99: "Thunderstorm with hail"
        default: "—"
        }
    }

    public static func symbol(_ code: Int, isDay: Bool = true) -> String {
        switch code {
        case 0: isDay ? "sun.max.fill" : "moon.stars.fill"
        case 1, 2: isDay ? "cloud.sun.fill" : "cloud.moon.fill"
        case 3: "cloud.fill"
        case 45, 48: "cloud.fog.fill"
        case 51, 53, 55, 56, 57: "cloud.drizzle.fill"
        case 61, 63, 66: "cloud.rain.fill"
        case 65, 67, 82: "cloud.heavyrain.fill"
        case 71, 73, 75, 77, 85, 86: "cloud.snow.fill"
        case 80, 81: isDay ? "cloud.sun.rain.fill" : "cloud.moon.rain.fill"
        case 95, 96, 99: "cloud.bolt.rain.fill"
        default: "cloud"
        }
    }
}
