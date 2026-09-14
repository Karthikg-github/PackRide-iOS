import Foundation
import CoreLocation
import FirebaseDatabase

struct NearbyTrackConfiguration: Identifiable {
    let id: String
    let name: String
    let timing: TrackTimingConfiguration?
    let centerline: [CLLocationCoordinate2D]
    let isDefault: Bool
    let source: String
    let verificationStatus: String
    let confirmationCount: Int
}

struct NearbyTrackDefinition: Identifiable {
    let id: String
    let name: String
    let center: CLLocationCoordinate2D
    let verificationStatus: String
    let distanceMiles: Double
    let configurations: [NearbyTrackConfiguration]
}

enum TrackCatalogService {
    static func nearby(to location: CLLocation, radiusMiles: Double = 10, completion: @escaping ([NearbyTrackDefinition]) -> Void) {
        Database.database().reference().child("tracks").observeSingleEvent(of: .value) { snapshot in
            let tracks = parse(snapshot: snapshot, relativeTo: location)
                .filter { $0.distanceMiles <= radiusMiles }
                .sorted { $0.distanceMiles < $1.distanceMiles }
            DispatchQueue.main.async { completion(tracks) }
        } withCancel: { _ in DispatchQueue.main.async { completion([]) } }
    }

    /// Finds configured tracks by name regardless of distance. Typed Track Mode
    /// searches use this before MapKit so a known venue loads its authoritative
    /// timing gates instead of guessing a line at the venue's map pin.
    static func matching(name query: String, near location: CLLocation?, completion: @escaping ([NearbyTrackDefinition]) -> Void) {
        let needle = normalized(query)
        guard !needle.isEmpty else { completion([]); return }
        Database.database().reference().child("tracks").observeSingleEvent(of: .value) { snapshot in
            let origin = location ?? CLLocation(latitude: 0, longitude: 0)
            let matches = parse(snapshot: snapshot, relativeTo: origin)
                .compactMap { track -> (NearbyTrackDefinition, Int)? in
                    matchScore(needle: needle, track: track).map { (track, $0) }
                }
                .sorted {
                    $0.1 == $1.1 ? $0.0.distanceMiles < $1.0.distanceMiles : $0.1 > $1.1
                }
                .map(\.0)
            DispatchQueue.main.async { completion(matches) }
        } withCancel: { _ in DispatchQueue.main.async { completion([]) } }
    }

    private static func parse(snapshot: DataSnapshot, relativeTo location: CLLocation) -> [NearbyTrackDefinition] {
        let root = snapshot.value as? [String: Any] ?? [:]
        return root.compactMap { id, raw -> NearbyTrackDefinition? in
                guard let data = raw as? [String: Any], let center = point(data["center"] as? [String: Any]),
                      let configs = data["configurations"] as? [String: Any] else { return nil }
                let distance = location.distance(from: CLLocation(latitude: center.latitude, longitude: center.longitude)) / 1609.344
                let parsed = configs.compactMap { configID, rawConfig -> NearbyTrackConfiguration? in
                    guard let config = rawConfig as? [String: Any] else { return nil }
                    let sectors: [TimingGate]
                    if let list = config["sectorGates"] as? [[String: Any]] {
                        sectors = list.enumerated().compactMap { gate($0.element, id: "sector-\($0.offset)") }
                    } else if let map = config["sectorGates"] as? [String: Any] {
                        sectors = map.compactMap { gate($0.value as? [String: Any], id: $0.key) }
                    } else { sectors = [] }
                    let centerline = (config["centerline"] as? [[String: Any]] ?? []).compactMap { point($0) }
                    let timing = gate(config["startFinishGate"] as? [String: Any], id: "start-finish").map { start in
                        TrackTimingConfiguration(
                            startFinish: start, sectors: sectors,
                            finishGate: gate(config["finishGate"] as? [String: Any], id: "finish"),
                            pitEntryGate: gate(config["pitEntryGate"] as? [String: Any], id: "pit-entry"),
                            pitExitGate: gate(config["pitExitGate"] as? [String: Any], id: "pit-exit")
                        )
                    }
                    // A highway=raceway venue often contains pit lanes,
                    // connectors and individual way fragments. Those are not
                    // selectable circuit layouts. Keep reviewed timing data,
                    // otherwise require a plausible closed full lap.
                    guard timing != nil || usableClosedCircuit(centerline) else { return nil }
                    return NearbyTrackConfiguration(
                        id: configID,
                        name: config["name"] as? String ?? "Main Circuit",
                        timing: timing,
                        centerline: centerline,
                        isDefault: config["isDefault"] as? Bool ?? false,
                        source: config["source"] as? String ?? data["source"] as? String ?? "unknown",
                        verificationStatus: config["verificationStatus"] as? String ?? data["verificationStatus"] as? String ?? "unverified",
                        confirmationCount: (config["confirmationCount"] as? NSNumber)?.intValue ?? 0
                    )
                }
                guard !parsed.isEmpty else { return nil }
                return NearbyTrackDefinition(id: id, name: data["name"] as? String ?? "Track", center: center,
                    verificationStatus: data["verificationStatus"] as? String ?? "unverified", distanceMiles: distance,
                    configurations: parsed.sorted {
                        if $0.isDefault != $1.isDefault { return $0.isDefault }
                        if $0.confirmationCount != $1.confirmationCount { return $0.confirmationCount > $1.confirmationCount }
                        return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
                    })
            }
    }

    private static func normalized(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .joined(separator: " ")
            .split(separator: " ").joined(separator: " ")
    }

    /// Prevent tiny/broken catalogue names such as "H" from matching every
    /// query that happens to contain that letter. Exact and meaningful partial
    /// venue-name matches remain supported.
    private static func matchScore(needle: String, track: NearbyTrackDefinition) -> Int? {
        let candidate = normalized(track.name)
        guard !candidate.isEmpty else { return nil }
        if candidate == needle { return 1_000 }
        if candidate.hasPrefix(needle + " ") { return 900 }
        if candidate.contains(" " + needle + " ") || candidate.hasSuffix(" " + needle) { return 850 }
        if needle.count >= 4, candidate.contains(needle) { return 800 }
        if candidate.count >= 4, needle.contains(candidate) { return 700 }
        return nil
    }

    private static func usableClosedCircuit(_ points: [CLLocationCoordinate2D]) -> Bool {
        guard points.count >= 12, let first = points.first, let last = points.last else { return false }
        guard CLLocation(latitude: first.latitude, longitude: first.longitude)
            .distance(from: CLLocation(latitude: last.latitude, longitude: last.longitude)) <= 60 else { return false }
        var length = 0.0
        for index in 1..<points.count {
            length += CLLocation(latitude: points[index - 1].latitude, longitude: points[index - 1].longitude)
                .distance(from: CLLocation(latitude: points[index].latitude, longitude: points[index].longitude))
        }
        return length >= 100
    }

    private static func point(_ data: [String: Any]?) -> CLLocationCoordinate2D? {
        guard let data,
              let lat = (data["latitude"] ?? data["lat"]) as? NSNumber,
              let lng = (data["longitude"] ?? data["lng"] ?? data["lon"]) as? NSNumber else { return nil }
        return CLLocationCoordinate2D(latitude: lat.doubleValue, longitude: lng.doubleValue)
    }

    private static func gate(_ data: [String: Any]?, id: String) -> TimingGate? {
        guard let data, let a = point(data["a"] as? [String: Any]), let b = point(data["b"] as? [String: Any]) else { return nil }
        let raw = (data["direction"] as? String)?.lowercased()
        let direction: GateDirection = ["negative_to_positive", "negativetopositive", "forward"].contains(raw ?? "") ? .negativeToPositive : .positiveToNegative
        return TimingGate(id: id, a: a, b: b, direction: direction)
    }
}
