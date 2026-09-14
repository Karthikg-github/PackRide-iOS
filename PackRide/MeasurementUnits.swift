import Foundation

enum MeasurementSystem: String, CaseIterable, Identifiable {
    case imperial
    case metric
    var id: String { rawValue }
}

/// Display-only conversions. Existing Firebase values remain in their current
/// canonical units, preserving compatibility with already-recorded rides and Android.
enum MeasurementUnits {
    static let preferenceKey = "measurementSystem"
    static var current: MeasurementSystem {
        MeasurementSystem(rawValue: UserDefaults.standard.string(forKey: preferenceKey) ?? "imperial") ?? .imperial
    }

    private static func number(_ value: Double, decimals: Int) -> String {
        String(format: "%.*f", decimals, value)
    }

    static func distanceMiles(_ miles: Double, decimals: Int = 1) -> String {
        current == .metric
            ? "\(number(miles * 1.609344, decimals: decimals)) km"
            : "\(number(miles, decimals: decimals)) mi"
    }

    static func milesToDisplay(_ miles: Double) -> Double {
        current == .metric ? miles * 1.609344 : miles
    }

    static func displayDistanceToMiles(_ value: Double) -> Double {
        current == .metric ? value / 1.609344 : value
    }

    static var distanceInputLabel: String { current == .metric ? "km" : "mi" }

    static func speedMph(_ mph: Double, decimals: Int = 0) -> String {
        current == .metric
            ? "\(number(mph * 1.609344, decimals: decimals)) km/h"
            : "\(number(mph, decimals: decimals)) mph"
    }

    static func distanceMeters(_ meters: Double, decimals: Int = 0) -> String {
        if current == .metric {
            return meters >= 1_000
                ? "\(number(meters / 1_000, decimals: 1)) km"
                : "\(number(meters, decimals: decimals)) m"
        }
        return meters >= 1_609.344
            ? "\(number(meters / 1_609.344, decimals: 1)) mi"
            : "\(number(meters * 3.28084, decimals: decimals)) ft"
    }

    static func temperatureF(_ fahrenheit: Double, decimals: Int = 0) -> String {
        current == .metric
            ? "\(number((fahrenheit - 32) * 5 / 9, decimals: decimals))°C"
            : "\(number(fahrenheit, decimals: decimals))°F"
    }

    static func elevationMeters(_ meters: Double, decimals: Int = 0) -> String {
        current == .metric
            ? "\(number(meters, decimals: decimals)) m"
            : "\(number(meters * 3.28084, decimals: decimals)) ft"
    }
}
