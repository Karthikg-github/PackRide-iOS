import Foundation
import CoreLocation
import MapKit
import Combine

// MARK: - Road Info Manager
// Looks up the current road name (via Apple's reverse geocoder — free, reliable)
// and posted speed limit (via the OpenStreetMap Overpass API — free, community-sourced,
// coverage varies by area) for the rider's current location.
//
// NOTE ON SPEED LIMIT DATA: Apple does not expose speed limit data to third-party
// apps, so this uses OpenStreetMap's public Overpass API. It's free but community
// maintained — some rural/back roads may not have a maxspeed tag yet, in which case
// we simply don't show a badge rather than guessing. Overpass is also not designed
// for heavy production traffic, so lookups are aggressively throttled below.
@MainActor
class RoadInfoManager: ObservableObject {
    @Published var roadName: String? = nil
    @Published var speedLimitMph: Int? = nil

    private var lastLookupLocation: CLLocation?
    private var lastLookupDate: Date?
    private var isLookingUp = false

    // Only re-query if the rider has moved far enough or enough time has passed —
    // keeps us well under Overpass's fair-use limits and avoids hammering the
    // geocoder during a ride.
    private let minDistanceMeters: CLLocationDistance = 150
    private let minInterval: TimeInterval = 20

    private let overpassEndpoints = [
        "https://overpass-api.de/api/interpreter",
        "https://overpass.kumi.systems/api/interpreter"
    ]

    func update(for location: CLLocation) {
        guard !isLookingUp else { return }
        if let last = lastLookupLocation, let lastDate = lastLookupDate {
            let movedFarEnough = location.distance(from: last) >= minDistanceMeters
            let enoughTimePassed = Date().timeIntervalSince(lastDate) >= minInterval
            guard movedFarEnough || enoughTimePassed else { return }
        }
        lastLookupLocation = location
        lastLookupDate = Date()
        isLookingUp = true

        Task {
            async let name = fetchRoadName(location)
            async let limit = fetchSpeedLimit(location)
            let (resolvedName, resolvedLimit) = await (name, limit)
            self.roadName = resolvedName ?? self.roadName
            self.speedLimitMph = resolvedLimit
            self.isLookingUp = false
        }
    }

    // MARK: - Road name (Apple reverse geocoding)
    // Aug 28, 2026 — MKReverseGeocodingRequest is iOS 26+ only; replaced
    // with CLGeocoder's async reverseGeocodeLocation (available since iOS
    // 15), which works at this project's 17.6 deployment target.
    private func fetchRoadName(_ location: CLLocation) async -> String? {
        do {
            guard let placemark = try await CLGeocoder().reverseGeocodeLocation(location).first else { return nil }
            // CLPlacemark.thoroughfare is already just the street name, no
            // house number attached — the direct, preferred case.
            if let thoroughfare = placemark.thoroughfare {
                return thoroughfare
            }
            // Fall back to the placemark's name when thoroughfare isn't
            // populated — .name can be a full street address ("1234 Main
            // St"), so drop a leading house number so the badge still
            // shows just the road name.
            guard let name = placemark.name else { return nil }
            let parts = name.split(separator: " ")
            if parts.count > 1, parts[0].allSatisfy({ $0.isNumber || $0 == "-" }) {
                return parts.dropFirst().joined(separator: " ")
            }
            return name
        } catch {
            return nil
        }
    }

    // MARK: - Speed limit (OpenStreetMap Overpass)
    private func fetchSpeedLimit(_ location: CLLocation) async -> Int? {
        let lat = location.coordinate.latitude
        let lon = location.coordinate.longitude
        let query = """
        [out:json][timeout:8];
        way(around:40,\(lat),\(lon))["highway"]["maxspeed"];
        out tags 8;
        """
        guard let url = URL(string: overpassEndpoints[0]) else { return nil }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = "data=\(query)".addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed).map { Data($0.utf8) }
        request.setValue("PackRideApp/1.0 (contact: karthikgundavarapu@gmail.com)", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 8

        do {
            let (data, _) = try await URLSession.shared.data(for: request)
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let elements = json["elements"] as? [[String: Any]] else { return nil }

            // Prefer drivable road types over service/parking-aisle style ways.
            let preferredTypes: Set<String> = ["motorway", "trunk", "primary", "secondary", "tertiary",
                                                "unclassified", "residential", "motorway_link", "trunk_link",
                                                "primary_link", "secondary_link", "tertiary_link"]

            let candidates = elements.compactMap { el -> (String, String)? in
                guard let tags = el["tags"] as? [String: String],
                      let maxspeed = tags["maxspeed"],
                      let highway = tags["highway"] else { return nil }
                return (highway, maxspeed)
            }

            let best = candidates.first(where: { preferredTypes.contains($0.0) }) ?? candidates.first
            guard let raw = best?.1 else { return nil }
            return Self.parseMaxSpeed(raw)
        } catch {
            return nil
        }
    }

    // Parses OSM's maxspeed tag formats: "25 mph", "45", "70 mph", "50 km/h", etc.
    // Per OSM convention, an unsuffixed number in the US is assumed to already be mph.
    static func parseMaxSpeed(_ raw: String) -> Int? {
        let trimmed = raw.trimmingCharacters(in: .whitespaces).lowercased()
        if trimmed.hasSuffix("mph") {
            let numeric = trimmed.replacingOccurrences(of: "mph", with: "").trimmingCharacters(in: .whitespaces)
            return Int(numeric)
        }
        if trimmed.hasSuffix("km/h") {
            let numeric = trimmed.replacingOccurrences(of: "km/h", with: "").trimmingCharacters(in: .whitespaces)
            guard let kmh = Double(numeric) else { return nil }
            return Int((kmh * 0.621371).rounded())
        }
        // No unit suffix — treat as mph (US default) if it's a plain number.
        if let plain = Int(trimmed) { return plain }
        return nil
    }
}
