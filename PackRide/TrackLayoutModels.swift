//
//  TrackLayoutModels.swift
//  PackRide
//
//  Created by Karthik Gundavarapu on 8/26/26.
//

import Foundation
import CoreLocation
import MapKit

/// Represents a specific track circuit configuration (e.g., COTA Full Circuit vs National Circuit)
struct TrackLayout: Identifiable, Codable {
    let id: String
    let trackName: String
    let layoutName: String
    let startFinishCoordinate: CodableCoordinate
    let geoJSONData: Data?
    
    struct CodableCoordinate: Codable {
        let latitude: Double
        let longitude: Double
        
        var clCoordinate: CLLocationCoordinate2D {
            CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
        }
    }
}
