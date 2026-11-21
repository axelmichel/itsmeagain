import Foundation
import Testing

@testable import Weather

@Suite struct WeatherTests {
    static let forecast = #"""
        {"current":{"temperature_2m":11.6,"apparent_temperature":9.2,"weather_code":3,"wind_speed_10m":18.4,"is_day":1},
         "hourly":{"time":[1795600000,1795603600,1795607200],"temperature_2m":[11.0,12.0,12.5],"weather_code":[3,61,80],"precipitation_probability":[10,60,null]},
         "daily":{"temperature_2m_max":[13.1,12.0],"temperature_2m_min":[8.4,7.0],"precipitation_probability_max":[70,30]}}
        """#

    @Test func parsesForecast() throws {
        let place = WeatherPlace(name: "Morlaix", country: "France", latitude: 48.58, longitude: -3.83)
        let report = try OpenMeteo.parse(Data(Self.forecast.utf8), place: place, now: Date(timeIntervalSince1970: 1_795_601_000))
        #expect(report.temperature == 11.6 && report.feelsLike == 9.2 && report.code == 3 && report.isDay)
        #expect(report.high == 13.1 && report.low == 8.4 && report.precipitationChance == 70)
        #expect(report.hours.map(\.temperature) == [11.0, 12.0, 12.5], "the current hour (within 30 min) counts")
        #expect(report.hours.last?.precipitationChance == 0, "missing values become 0")
    }

    @Test func geocodingAndForecastRequests() async throws {
        let (session, base) = StubURLProtocol.make { request, _ in
            if request.url?.path() == "/v1/search" {
                #expect(request.url?.query()?.contains("name=Morlaix") == true)
                return .init(body: Data(#"{"results":[{"name":"Morlaix","country":"France","latitude":48.58,"longitude":-3.83}]}"#.utf8))
            }
            #expect(request.url?.query()?.contains("latitude=48.5800") == true)
            return .init(body: Data(Self.forecast.utf8))
        }
        let client = OpenMeteo(session: session, geocodingBase: base, forecastBase: base)
        let places = try await client.places(matching: "Morlaix")
        #expect(places.first?.country == "France")
        let report = try await client.report(for: places[0], now: Date(timeIntervalSince1970: 1_795_601_000))
        #expect(report.place.name == "Morlaix")
    }

    @Test func codes() {
        #expect(WeatherCode.text(61) == "Light rain" && WeatherCode.symbol(61) == "cloud.rain.fill")
        #expect(WeatherCode.symbol(0, isDay: false) == "moon.stars.fill")
    }
}
