import Foundation
import WeatherKit
import CoreLocation
import MapKit
import Combine

// MARK: - Ride Weather Info
struct RideWeatherInfo: Identifiable {
    let id = UUID()
    let locationName: String
    let coordinate: CLLocationCoordinate2D
    let temperature: Double        // Fahrenheit
    let feelsLike: Double
    let condition: String          // "Clear", "Rain", etc.
    let symbolName: String         // SF Symbol name
    let windSpeed: Double          // mph
    let windDirection: String
    let humidity: Double           // 0-1
    let precipChance: Double       // 0-1
    let uvIndex: Int
    let visibility: Double         // miles
    let isRideSafe: Bool           // our recommendation

    var tempString: String { MeasurementUnits.temperatureF(temperature) }
    var feelsLikeString: String { MeasurementUnits.temperatureF(feelsLike) }
    var windString: String { "\(MeasurementUnits.speedMph(windSpeed)) \(windDirection)" }
    var humidityString: String { "\(Int(humidity * 100))%" }
    var precipString: String { "\(Int(precipChance * 100))%" }
    var visibilityString: String { MeasurementUnits.distanceMiles(visibility) }

    var safetyColor: String {
        if precipChance > 0.5 || windSpeed > 30 { return "red" }
        if precipChance > 0.2 || windSpeed > 20 || temperature < 40 { return "yellow" }
        return "green"
    }

    var safetyLabel: String {
        switch safetyColor {
        case "red": return "Poor Conditions"
        case "yellow": return "Use Caution"
        default: return "Great Riding"
        }
    }
}

// MARK: - Hourly Forecast
struct HourlyRideForecast: Identifiable {
    let id = UUID()
    let hour: Date
    let temperature: Double
    let symbolName: String
    let precipChance: Double
    let windSpeed: Double

    var hourString: String {
        let f = DateFormatter(); f.dateFormat = "ha"
        return f.string(from: hour)
    }
}

// MARK: - Weather-Ahead: forecast at a stop's ESTIMATED ARRIVAL time
// (not "right now"). Distinct from RideWeatherInfo above, which is always
// current-conditions-at-a-location — this instead answers "what will the
// weather be like when I actually get there", using WeatherKit's hourly
// forecast (same `service.weather(for:).hourlyForecast` WeatherManager
// already calls for the current-location strip) matched to an assumed
// arrival hour rather than the first/current entry.
struct RouteAheadForecast: Identifiable {
    let id = UUID()
    let stopName: String
    let coordinate: CLLocationCoordinate2D
    let cumulativeMiles: Double     // straight-line distance from the route start, summed leg by leg
    let etaDate: Date               // estimated arrival — see WeatherManager.assumedAveragePaceMPH
    let temperature: Double         // Fahrenheit, at the closest available forecast hour to etaDate
    let symbolName: String
    let condition: String
    let precipChance: Double
    let windSpeed: Double           // mph
    let isRideSafe: Bool

    var tempString: String { MeasurementUnits.temperatureF(temperature) }
    var milesString: String { MeasurementUnits.distanceMiles(cumulativeMiles) }
    var etaString: String {
        let f = DateFormatter(); f.dateFormat = "h:mm a"
        return f.string(from: etaDate)
    }
    var precipString: String { "\(Int(precipChance * 100))%" }
    var windString: String { MeasurementUnits.speedMph(windSpeed) }

    var safetyColor: String {
        if precipChance > 0.5 || windSpeed > 30 { return "red" }
        if precipChance > 0.2 || windSpeed > 20 || temperature < 40 { return "yellow" }
        return "green"
    }
    var safetyLabel: String {
        switch safetyColor {
        case "red": return "Poor Conditions"
        case "yellow": return "Use Caution"
        default: return "Great Riding"
        }
    }
}

// MARK: - Weather Manager
class WeatherManager: ObservableObject {
    @Published var currentWeather: RideWeatherInfo?
    @Published var waypointWeather: [RideWeatherInfo] = []
    @Published var hourlyForecast: [HourlyRideForecast] = []
    @Published var isLoading = false
    @Published var lastError: String? = nil

    // MARK: - Weather-Ahead state (route-forecast-at-ETA — see RouteAheadForecast above)
    @Published var routeAheadForecasts: [RouteAheadForecast] = []
    @Published var isLoadingRouteAhead = false
    @Published var routeAheadError: String? = nil

    // Blended average pace used ONLY to estimate arrival time at each stop
    // from straight-line (crow-flies) distance — deliberately well under a
    // real highway cruising speed to account for stop signs, turns, fuel/food
    // breaks, and traffic along an actual route that a straight line doesn't
    // capture. This is an honest estimate, not routed ETA (no MapKit/Directions
    // API involved) — RouteWeatherAheadView surfaces that caveat to the rider.
    static let assumedAveragePaceMPH: Double = 30.0

    private let service = WeatherService.shared

    // MARK: - Fetch current location weather
    func fetchCurrentWeather(location: CLLocation, locationName: String = "Current Location") async {
        await MainActor.run { isLoading = true }

        // If the caller didn't pass a specific name, reverse-geocode the
        // coordinate to show an actual city name instead of the generic
        // placeholder.
        var resolvedName = locationName
        if locationName == "Current Location" {
            resolvedName = await Self.cityName(for: location) ?? locationName
        }

        do {
            let weather = try await service.weather(for: location)
            let current = weather.currentWeather
            let info = RideWeatherInfo(
                locationName: resolvedName,
                coordinate: location.coordinate,
                temperature: current.temperature.converted(to: .fahrenheit).value,
                feelsLike: current.apparentTemperature.converted(to: .fahrenheit).value,
                condition: current.condition.description,
                symbolName: current.symbolName,
                windSpeed: current.wind.speed.converted(to: .milesPerHour).value,
                windDirection: compassDirection(from: current.wind.direction.converted(to: .degrees).value),
                humidity: current.humidity,
                precipChance: weather.hourlyForecast.first?.precipitationChance ?? 0,
                uvIndex: current.uvIndex.value,
                visibility: current.visibility.converted(to: .miles).value,
                isRideSafe: current.wind.speed.converted(to: .milesPerHour).value < 30 &&
                           (weather.hourlyForecast.first?.precipitationChance ?? 0) < 0.5
            )
            await MainActor.run {
                self.currentWeather = info
                self.isLoading = false
            }

            // Also fetch hourly
            let hourly = weather.hourlyForecast.prefix(12).map { hour in
                HourlyRideForecast(
                    hour: hour.date,
                    temperature: hour.temperature.converted(to: .fahrenheit).value,
                    symbolName: hour.symbolName,
                    precipChance: hour.precipitationChance,
                    windSpeed: hour.wind.speed.converted(to: .milesPerHour).value
                )
            }
            await MainActor.run { self.hourlyForecast = Array(hourly) }
        } catch {
            print("Weather fetch error: \(error)")
            await MainActor.run {
                self.isLoading = false
                self.lastError = error.localizedDescription
            }
        }
    }

    // MARK: - Fetch weather for waypoints along a route
    func fetchRouteWeather(waypoints: [(name: String, coordinate: CLLocationCoordinate2D)]) async {
        await MainActor.run { isLoading = true; waypointWeather = [] }
        var results: [RideWeatherInfo] = []

        for wp in waypoints {
            do {
                let location = CLLocation(latitude: wp.coordinate.latitude, longitude: wp.coordinate.longitude)
                let weather = try await service.weather(for: location)
                let current = weather.currentWeather
                let info = RideWeatherInfo(
                    locationName: wp.name,
                    coordinate: wp.coordinate,
                    temperature: current.temperature.converted(to: .fahrenheit).value,
                    feelsLike: current.apparentTemperature.converted(to: .fahrenheit).value,
                    condition: current.condition.description,
                    symbolName: current.symbolName,
                    windSpeed: current.wind.speed.converted(to: .milesPerHour).value,
                    windDirection: compassDirection(from: current.wind.direction.converted(to: .degrees).value),
                    humidity: current.humidity,
                    precipChance: weather.hourlyForecast.first?.precipitationChance ?? 0,
                    uvIndex: current.uvIndex.value,
                    visibility: current.visibility.converted(to: .miles).value,
                    isRideSafe: current.wind.speed.converted(to: .milesPerHour).value < 30 &&
                               (weather.hourlyForecast.first?.precipitationChance ?? 0) < 0.5
                )
                results.append(info)
            } catch {
                print("Weather error for \(wp.name): \(error)")
            }
        }

        await MainActor.run {
            self.waypointWeather = results
            self.isLoading = false
        }
    }

    // MARK: - Weather-Ahead: forecast at each stop's estimated arrival time
    // `startCoordinate` is the rider's current location if known (nil is fine
    // — the estimate then just starts its cumulative distance from the first
    // stop instead of from "now"). `stops` must already be in route order.
    func fetchRouteAheadWeather(startCoordinate: CLLocationCoordinate2D?, stops: [(name: String, coordinate: CLLocationCoordinate2D)]) async {
        await MainActor.run { isLoadingRouteAhead = true; routeAheadForecasts = []; routeAheadError = nil }
        guard !stops.isEmpty else {
            await MainActor.run { isLoadingRouteAhead = false }
            return
        }

        var cumulativeMeters: Double = 0
        var previousCoordinate = startCoordinate
        let departureTime = Date()
        var results: [RouteAheadForecast] = []

        for stop in stops {
            if let previous = previousCoordinate {
                let from = CLLocation(latitude: previous.latitude, longitude: previous.longitude)
                let to = CLLocation(latitude: stop.coordinate.latitude, longitude: stop.coordinate.longitude)
                // Straight-line (great-circle) leg distance — same "as the
                // crow flies" measurement WaypointsView's route-planning
                // preview uses, summed cumulatively leg by leg so later stops
                // account for every leg before them, not just the direct line
                // from the start.
                cumulativeMeters += from.distance(from: to)
            }
            previousCoordinate = stop.coordinate

            let cumulativeMiles = cumulativeMeters * 0.000621371
            let hoursElapsed = cumulativeMiles / Self.assumedAveragePaceMPH
            let eta = departureTime.addingTimeInterval(hoursElapsed * 3600)

            do {
                let location = CLLocation(latitude: stop.coordinate.latitude, longitude: stop.coordinate.longitude)
                let weather = try await service.weather(for: location)
                // WeatherKit's hourlyForecast spans several days — pick the
                // single entry whose timestamp is closest to this stop's
                // estimated arrival hour rather than always using the first
                // (current-hour) entry the way fetchRouteWeather above does.
                guard let hour = weather.hourlyForecast.min(by: {
                    abs($0.date.timeIntervalSince(eta)) < abs($1.date.timeIntervalSince(eta))
                }) else { continue }

                let windMPH = hour.wind.speed.converted(to: .milesPerHour).value
                results.append(RouteAheadForecast(
                    stopName: stop.name,
                    coordinate: stop.coordinate,
                    cumulativeMiles: cumulativeMiles,
                    etaDate: eta,
                    temperature: hour.temperature.converted(to: .fahrenheit).value,
                    symbolName: hour.symbolName,
                    condition: hour.condition.description,
                    precipChance: hour.precipitationChance,
                    windSpeed: windMPH,
                    isRideSafe: windMPH < 30 && hour.precipitationChance < 0.5
                ))
            } catch {
                print("Route-ahead weather error for \(stop.name): \(error)")
            }
        }

        await MainActor.run {
            self.routeAheadForecasts = results
            self.isLoadingRouteAhead = false
            if results.isEmpty { self.routeAheadError = "Couldn't load a forecast for this route" }
        }
    }

    // MARK: - Helper
    private func compassDirection(from degrees: Double) -> String {
        let dirs = ["N", "NNE", "NE", "ENE", "E", "ESE", "SE", "SSE",
                    "S", "SSW", "SW", "WSW", "W", "WNW", "NW", "NNW"]
        let index = Int((degrees + 11.25) / 22.5) % 16
        return dirs[index]
    }

    /// Reverse-geocodes a coordinate to a short, human-readable place name
    /// (city, or a sensible fallback if the city name isn't available).
    // Aug 28, 2026 — MKReverseGeocodingRequest is iOS 26+ only; replaced
    // with CLGeocoder's async reverseGeocodeLocation (available since iOS
    // 15), which works at this project's 17.6 deployment target.
    private static func cityName(for location: CLLocation) async -> String? {
        do {
            guard let placemark = try await CLGeocoder().reverseGeocodeLocation(location).first else { return nil }
            return placemark.locality ?? placemark.name
        } catch {
            return nil
        }
    }
}
