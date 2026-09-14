import Foundation
import MapKit
import AVFoundation
import CoreLocation
import Combine

// MARK: - Route Step
struct RouteStep: Identifiable {
    let id = UUID()
    let instruction: String
    let distance: Double          // meters
    let coordinate: CLLocationCoordinate2D
    var isCompleted: Bool = false

    var distanceString: String {
        return MeasurementUnits.distanceMeters(distance)
    }

    var maneuverIcon: String {
        let lower = instruction.lowercased()
        if lower.contains("left") && lower.contains("slight") { return "arrow.turn.up.left" }
        if lower.contains("right") && lower.contains("slight") { return "arrow.turn.up.right" }
        if lower.contains("left") { return "arrow.turn.down.left" }
        if lower.contains("right") { return "arrow.turn.down.right" }
        if lower.contains("u-turn") { return "arrow.uturn.down" }
        if lower.contains("merge") { return "arrow.merge" }
        if lower.contains("exit") { return "arrow.up.right" }
        if lower.contains("straight") || lower.contains("continue") { return "arrow.up" }
        if lower.contains("arrive") || lower.contains("destination") { return "flag.checkered" }
        if lower.contains("roundabout") { return "arrow.triangle.capsulepath" }
        return "arrow.up"
    }
}

// MARK: - Navigation State
enum NavigationState {
    case idle
    case calculating
    case navigating
    case rerouting
    case arrived
}

// MARK: - Navigation Manager
class NavigationManager: NSObject, ObservableObject {
    // State
    @Published var state: NavigationState = .idle
    @Published var steps: [RouteStep] = []
    @Published var currentStepIndex: Int = 0
    // Aug 30, 2026 — was a single MKPolyline?, overwritten only when the
    // FIRST leg (current location -> start override / first stop)
    // finished, so a multi-leg route (start override, or 2+ waypoints)
    // only ever drew the very first segment on the map — every leg after
    // that calculated fine (its distance/time/turn steps all fed into the
    // totals and the step list below) but its polyline was silently
    // discarded. Now one polyline per leg, rendered as separate overlays
    // by TurnByTurnView so the whole route (through every via-point to
    // the actual destination) draws, not just the first hop.
    @Published var routePolylines: [MKPolyline] = []
    @Published var distanceRemaining: Double = 0     // meters
    @Published var etaMinutes: Int = 0
    @Published var isVoiceEnabled: Bool = true
    @Published var distanceToNextStep: Double = 0    // meters
    @Published var isOffRoute: Bool = false

    // Voice
    private let synthesizer = AVSpeechSynthesizer()
    private var hasAnnouncedStep: Set<Int> = []

    // Route
    // Aug 30, 2026 — was a single MKRoute? (also only ever the first leg,
    // same bug as routePolyline above) used for off-route detection in
    // updatePosition — meaning a rider was only ever checked against the
    // first leg of the route, never flagged as off-route while actually
    // on a later leg. Now one MKRoute per leg, all considered.
    private var legRoutes: [MKRoute] = []
    private var destinationCoordinate: CLLocationCoordinate2D?
    private var waypointCoordinates: [CLLocationCoordinate2D] = []
    private var currentWaypointIndex: Int = 0

    // Thresholds
    private let stepCompletionDistance: Double = 40    // meters — mark step done
    private let earlyWarningDistance: Double = 200     // meters — "in 200 meters, turn..."
    private let offRouteDistance: Double = 100          // meters — trigger reroute
    private let arrivalDistance: Double = 50           // meters — you've arrived

    var currentStep: RouteStep? {
        guard steps.indices.contains(currentStepIndex) else { return nil }
        return steps[currentStepIndex]
    }

    var nextStep: RouteStep? {
        let next = currentStepIndex + 1
        guard steps.indices.contains(next) else { return nil }
        return steps[next]
    }

    var etaString: String {
        if etaMinutes < 60 { return "\(etaMinutes) min" }
        return "\(etaMinutes / 60)h \(etaMinutes % 60)m"
    }

    var distanceRemainingString: String {
        return MeasurementUnits.distanceMeters(distanceRemaining)
    }

    // MARK: - Calculate Route
    func calculateRoute(from: CLLocationCoordinate2D, to: CLLocationCoordinate2D,
                         waypoints: [CLLocationCoordinate2D] = []) {
        state = .calculating
        waypointCoordinates = waypoints
        destinationCoordinate = to
        // Aug 30, 2026 — clear any legs left over from a previous
        // calculateRoute call (e.g. a reroute()) before this one starts
        // appending its own, so a leg that fails to come back doesn't
        // leave a stale, no-longer-relevant segment drawn on the map.
        legRoutes = []
        routePolylines = []

        // Build full route: from -> waypoint1 -> waypoint2 -> ... -> to
        let allPoints = [from] + waypoints + [to]
        let legCount = allPoints.count - 1
        // Aug 30, 2026 — each leg is requested concurrently below, so
        // completions can land in any order. Collecting into an
        // index-slotted array (instead of appending straight into a
        // shared `allSteps`, as this used to) means the turn-by-turn
        // step list still comes out start-to-finish in route order once
        // flattened after group.notify, regardless of which leg's
        // network request happened to finish first — same race that let
        // the polyline bug below only ever show/consider the first leg.
        var legResults: [MKRoute?] = Array(repeating: nil, count: legCount)
        let group = DispatchGroup()

        for i in 0..<legCount {
            group.enter()
            let request = MKDirections.Request()
            // Aug 28, 2026 — MKMapItem(location:address:) is iOS 26+ only;
            // the project's deployment target needs to go lower than that
            // for compatibility, so back to the MKPlacemark-based
            // initializer every iOS version since MapKit's introduction
            // supports.
            request.source = MKMapItem(placemark: MKPlacemark(coordinate: allPoints[i]))
            request.destination = MKMapItem(placemark: MKPlacemark(coordinate: allPoints[i + 1]))
            request.transportType = .automobile
            request.requestsAlternateRoutes = false

            MKDirections(request: request).calculate { response, error in
                guard let route = response?.routes.first else {
                    print("Route error: \(error?.localizedDescription ?? "unknown")")
                    group.leave()
                    return
                }
                // Aug 30, 2026 — legResults is shared across every leg's
                // concurrent completion handler (each on its own
                // MapKit-internal queue); writing to it straight from
                // there is an unsynchronized race even though each leg
                // touches a different index. Hopping to main (already
                // where group.notify below reads the array back) makes
                // every write to it happen one at a time.
                DispatchQueue.main.async {
                    legResults[i] = route
                    group.leave()
                }
            }
        }

        group.notify(queue: .main) {
            // Aug 30, 2026 — used to only ever keep leg 0's route/polyline
            // (self.fullRoute = route only when i == 0) and only ever
            // append leg 0's steps in a race-safe way by accident — every
            // leg after the first (e.g. start-override -> destination,
            // or stop 1 -> stop 2) calculated correctly and fed its
            // distance/time into the totals, but its polyline never made
            // it onto the map and its steps could land anywhere in the
            // list depending on network timing. Now every leg that came
            // back is kept, in order.
            let routes = legResults.compactMap { $0 }
            guard !routes.isEmpty else {
                self.state = .idle
                return
            }
            self.legRoutes = routes
            self.routePolylines = routes.map { $0.polyline }
            self.steps = routes.flatMap { route in
                route.steps.filter { !$0.instructions.isEmpty }.map {
                    RouteStep(instruction: $0.instructions, distance: $0.distance, coordinate: $0.polyline.coordinate)
                }
            }
            self.distanceRemaining = routes.reduce(0) { $0 + $1.distance }
            self.etaMinutes = Int(routes.reduce(0) { $0 + $1.expectedTravelTime } / 60)
            self.currentStepIndex = 0
            self.hasAnnouncedStep = []
            self.state = self.steps.isEmpty ? .idle : .navigating

            // Announce first step
            if self.state == .navigating {
                self.announceCurrentStep()
            }
        }
    }

    // MARK: - Update Position (call on every GPS update)
    func updatePosition(_ location: CLLocation) {
        guard state == .navigating, !steps.isEmpty else { return }

        let userCoord = location.coordinate

        // Check arrival at final destination
        if let dest = destinationCoordinate {
            let destLoc = CLLocation(latitude: dest.latitude, longitude: dest.longitude)
            if location.distance(from: destLoc) < arrivalDistance {
                arrive()
                return
            }
        }

        // Distance to current step
        if let step = currentStep {
            let stepLoc = CLLocation(latitude: step.coordinate.latitude, longitude: step.coordinate.longitude)
            distanceToNextStep = location.distance(from: stepLoc)

            // Step completed — move to next
            if distanceToNextStep < stepCompletionDistance {
                completeCurrentStep()
            }
            // Early warning for next step
            else if distanceToNextStep < earlyWarningDistance && !hasAnnouncedStep.contains(currentStepIndex) {
                announceCurrentStep()
            }
        }

        // Check if off route (simplified)
        // Aug 30, 2026 — used to only check distance against fullRoute
        // (leg 0 only), so a rider was never actually flagged as off
        // route while on any leg after the first (e.g. already past the
        // start override, heading to the real destination). Now checks
        // against every leg.
        if !legRoutes.isEmpty {
            let routePoints = legRoutes.flatMap { $0.polyline.coordinates }
            let minDist = routePoints.map { coord -> Double in
                CLLocation(latitude: coord.latitude, longitude: coord.longitude).distance(from: location)
            }.min() ?? 0

            if minDist > offRouteDistance && !isOffRoute {
                isOffRoute = true
                reroute(from: userCoord)
            } else if minDist < offRouteDistance {
                isOffRoute = false
            }
        }

        // Update remaining distance
        if let step = currentStep {
            let stepLoc = CLLocation(latitude: step.coordinate.latitude, longitude: step.coordinate.longitude)
            let distToStep = location.distance(from: stepLoc)
            let remainingStepsDist = steps.dropFirst(currentStepIndex + 1).reduce(0.0) { $0 + $1.distance }
            distanceRemaining = distToStep + remainingStepsDist
            etaMinutes = max(1, Int(distanceRemaining / (location.speed > 0 ? location.speed : 13.4) / 60))
        }
    }

    // MARK: - Step Management
    private func completeCurrentStep() {
        guard steps.indices.contains(currentStepIndex) else { return }
        steps[currentStepIndex].isCompleted = true

        if currentStepIndex < steps.count - 1 {
            currentStepIndex += 1
            announceCurrentStep()
        } else {
            arrive()
        }
    }

    private func arrive() {
        state = .arrived
        speak("You have arrived at your destination.")
    }

    // MARK: - Reroute
    private func reroute(from coordinate: CLLocationCoordinate2D) {
        state = .rerouting
        speak("Recalculating route.")

        guard let dest = destinationCoordinate else { return }
        let remaining = Array(waypointCoordinates.dropFirst(currentWaypointIndex))
        calculateRoute(from: coordinate, to: dest, waypoints: remaining)
    }

    // MARK: - Voice
    func announceCurrentStep() {
        guard let step = currentStep else { return }
        hasAnnouncedStep.insert(currentStepIndex)

        let distText: String
        distText = "In \(MeasurementUnits.distanceMeters(step.distance))"

        speak("\(distText), \(step.instruction)")
    }

    func speak(_ text: String) {
        guard isVoiceEnabled else { return }
        synthesizer.stopSpeaking(at: .immediate)

        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: "en-US")
        utterance.rate = 0.5
        utterance.pitchMultiplier = 1.0
        utterance.volume = 1.0

        // Enable audio even when phone is silent/screen off
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .voicePrompt, options: [.duckOthers])
        try? AVAudioSession.sharedInstance().setActive(true)

        synthesizer.speak(utterance)
    }

    func toggleVoice() {
        isVoiceEnabled.toggle()
        if !isVoiceEnabled { synthesizer.stopSpeaking(at: .immediate) }
    }

    // MARK: - Stop
    func stopNavigation() {
        state = .idle
        steps = []
        currentStepIndex = 0
        routePolylines = []
        legRoutes = []
        synthesizer.stopSpeaking(at: .immediate)
        hasAnnouncedStep = []
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}
