import Foundation
import MapKit
import CoreLocation

// MARK: - Global Track Layout Fetcher (Overpass / OpenStreetMap)
final class TrackLayoutService {
    
    /// Fetches track polyline vectors directly from OpenStreetMap (`highway=raceway`)
    static func fetchNearbyTrackLayouts(around location: CLLocationCoordinate2D, radiusMeters: Double = 5000, completion: @escaping ([MKPolyline], Error?) -> Void) {
        let query = """
        [out:json][timeout:25];
        (
          way["highway"="raceway"](around:\(radiusMeters),\(location.latitude),\(location.longitude));
          relation["highway"="raceway"](around:\(radiusMeters),\(location.latitude),\(location.longitude));
        );
        out body;
        >;
        out skel qt;
        """
        
        guard let encodedQuery = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "https://overpass-api.de/api/interpreter?data=\(encodedQuery)") else {
            completion([], NSError(domain: "TrackLayoutService", code: 400, userInfo: [NSLocalizedDescriptionKey: "Invalid URL"]))
            return
        }
        
        var request = URLRequest(url: url)
        request.timeoutInterval = 8
        request.cachePolicy = .returnCacheDataElseLoad
        URLSession.shared.dataTask(with: request) { data, response, error in
            guard let data = data, error == nil else {
                DispatchQueue.main.async { completion([], error) }
                return
            }
            if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                let statusError = NSError(domain: "TrackLayoutService", code: http.statusCode,
                    userInfo: [NSLocalizedDescriptionKey: "Track layout service returned HTTP \(http.statusCode)"])
                DispatchQueue.main.async { completion([], statusError) }
                return
            }
            
            let polylines = parseOverpassResponse(data: data)
            DispatchQueue.main.async {
                completion(polylines, nil)
            }
        }.resume()
    }
    
    private static func parseOverpassResponse(data: Data) -> [MKPolyline] {
        // Overpass returns its own element JSON, not GeoJSON. Decode nodes and
        // rebuild each raceway way in its declared order.
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let elements = root["elements"] as? [[String: Any]] else { return [] }
        var nodes: [Int64: CLLocationCoordinate2D] = [:]
        for element in elements where element["type"] as? String == "node" {
            guard let id = (element["id"] as? NSNumber)?.int64Value,
                  let latitude = element["lat"] as? Double,
                  let longitude = element["lon"] as? Double else { continue }
            nodes[id] = CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
        }
        return elements.compactMap { element in
            guard element["type"] as? String == "way",
                  let ids = element["nodes"] as? [NSNumber] else { return nil }
            let tags = element["tags"] as? [String: Any] ?? [:]
            let service = (tags["service"] as? String)?.lowercased() ?? ""
            guard !["pit_lane", "service", "driveway"].contains(service) else { return nil }
            let coordinates = ids.compactMap { nodes[$0.int64Value] }
            guard coordinates.count >= 12,
                  let first = coordinates.first, let last = coordinates.last,
                  CLLocation(latitude: first.latitude, longitude: first.longitude)
                    .distance(from: CLLocation(latitude: last.latitude, longitude: last.longitude)) <= 60
            else { return nil }
            return MKPolyline(coordinates: coordinates, count: coordinates.count)
        }
    }
}
