import Foundation
import CoreLocation
import FirebaseAuth
import FirebaseDatabase

enum CommunityLayoutSubmissionError: LocalizedError {
    case signedOut, insufficientLaps, insufficientPoints, openRoute

    var errorDescription: String? {
        switch self {
        case .signedOut: return "Sign in before submitting a community layout."
        case .insufficientLaps: return "Complete at least two valid laps before submitting this layout."
        case .insufficientPoints: return "There were not enough reliable GPS points to create a layout."
        case .openRoute: return "The recorded lap did not form a closed circuit."
        }
    }
}

enum CommunityTrackLayoutService {
    static func confirm(
        venueID: String,
        configurationID: String,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        guard let uid = Auth.auth().currentUser?.uid else {
            completion(.failure(CommunityLayoutSubmissionError.signedOut))
            return
        }
        let confirmationRef = Database.database().reference()
            .child("communityLayoutConfirmations")
            .child(venueID)
            .child(configurationID)
            .child(uid)
        confirmationRef.observeSingleEvent(of: .value) { snapshot in
            if snapshot.exists() {
                DispatchQueue.main.async { completion(.success(())) }
                return
            }
            confirmationRef.setValue([
                    "confirmedAt": ServerValue.timestamp(),
                    "source": "community_layout_selection"
                ]) { error, _ in
                    DispatchQueue.main.async {
                        error.map { completion(.failure($0)) } ?? completion(.success(()))
                    }
                }
        } withCancel: { error in
            DispatchQueue.main.async { completion(.failure(error)) }
        }
    }

    static func submit(
        venueName: String,
        layoutName: String,
        bestLapRoute: [CLLocationCoordinate2D],
        timing: TrackTimingConfiguration,
        completedLapCount: Int,
        timingConfidence: Double?,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        guard let uid = Auth.auth().currentUser?.uid else { completion(.failure(CommunityLayoutSubmissionError.signedOut)); return }
        guard completedLapCount >= 2 else { completion(.failure(CommunityLayoutSubmissionError.insufficientLaps)); return }
        let route = normalizedRoute(bestLapRoute)
        guard route.count >= 20 else { completion(.failure(CommunityLayoutSubmissionError.insufficientPoints)); return }
        let start = CLLocation(latitude: route[0].latitude, longitude: route[0].longitude)
        let end = CLLocation(latitude: route[route.count - 1].latitude, longitude: route[route.count - 1].longitude)
        guard start.distance(from: end) <= 80 else { completion(.failure(CommunityLayoutSubmissionError.openRoute)); return }

        let submissionID = UUID().uuidString
        let center = centroid(route)
        var payload: [String: Any] = [
            "venueName": venueName.trimmingCharacters(in: .whitespacesAndNewlines),
            "layoutName": layoutName.trimmingCharacters(in: .whitespacesAndNewlines),
            "center": point(center),
            "centerline": route.map { point($0) },
            "startFinishGate": gate(timing.startFinish),
            "sectorGates": timing.sectors.map { gate($0) },
            "createdBy": uid,
            "createdAt": ServerValue.timestamp(),
            "completedLapCount": completedLapCount,
            "timingConfidence": timingConfidence ?? 0,
            "status": "pending",
            "source": "community_phone_gps",
            "schemaVersion": 1
        ]
        if let value = timing.finishGate { payload["finishGate"] = gate(value) }
        if let value = timing.pitEntryGate { payload["pitEntryGate"] = gate(value) }
        if let value = timing.pitExitGate { payload["pitExitGate"] = gate(value) }
        Database.database().reference().child("communityLayoutSubmissions").child(submissionID)
            .setValue(payload) { error, _ in
                DispatchQueue.main.async { error.map { completion(.failure($0)) } ?? completion(.success(())) }
            }
    }

    private static func normalizedRoute(_ input: [CLLocationCoordinate2D]) -> [CLLocationCoordinate2D] {
        guard input.count > 2 else { return input }
        // A three-point moving average removes single-fix wobble without
        // rounding away real corners. Uniform decimation caps Firebase size.
        var smoothed: [CLLocationCoordinate2D] = [input[0]]
        for i in 1..<(input.count - 1) {
            smoothed.append(CLLocationCoordinate2D(
                latitude: (input[i - 1].latitude + input[i].latitude + input[i + 1].latitude) / 3,
                longitude: (input[i - 1].longitude + input[i].longitude + input[i + 1].longitude) / 3
            ))
        }
        smoothed.append(input[input.count - 1])
        let strideSize = max(1, Int(ceil(Double(smoothed.count) / 240.0)))
        var result = Swift.stride(from: 0, to: smoothed.count, by: strideSize).map { smoothed[$0] }
        if result.last?.latitude != smoothed.last?.latitude || result.last?.longitude != smoothed.last?.longitude {
            result.append(smoothed.last!)
        }
        return result
    }

    private static func centroid(_ route: [CLLocationCoordinate2D]) -> CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: route.map(\.latitude).reduce(0, +) / Double(route.count),
                               longitude: route.map(\.longitude).reduce(0, +) / Double(route.count))
    }

    private static func point(_ coordinate: CLLocationCoordinate2D) -> [String: Double] {
        ["latitude": coordinate.latitude, "longitude": coordinate.longitude]
    }

    private static func gate(_ value: TimingGate) -> [String: Any] {
        ["a": point(value.a), "b": point(value.b),
         "direction": value.direction == .negativeToPositive ? "negative_to_positive" : "positive_to_negative"]
    }
}
