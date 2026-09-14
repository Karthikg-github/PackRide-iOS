import Foundation
import CoreLocation
import Combine

// MARK: - Shared Location Manager (Singleton)
// One GPS instance for the entire app — saves battery vs 10 separate instances
final class SharedLocationManager: NSObject, ObservableObject, CLLocationManagerDelegate {
    static let shared = SharedLocationManager()

    private let manager = CLLocationManager()
    @Published var location: CLLocation?
    @Published var speed: Double = 0.0        // mph
    @Published var authStatus: CLAuthorizationStatus = .notDetermined

    // Tracking state
    @Published var isTracking = false
    @Published var distance: Double = 0.0     // miles
    @Published var maxSpeed: Double = 0.0     // mph
    private var lastTrackingLocation: CLLocation?
    private var lastLocationForSpeedFallback: CLLocation?

    // Background updates can be needed for more than one reason at the same
    // time — e.g. an active group ride (Group tab) and someone's live "Need
    // Help" share (Map tab) can both be running simultaneously, since neither
    // of those tabs is a modal that blocks the other. Reference-counted by
    // reason so one feature finishing doesn't turn off background delivery
    // something else still needs — this is one CLLocationManager for the
    // whole app, not a separate instance per feature.
    private var backgroundUpdateReasons: Set<String> = []

    // Aug 22, 2026 — plain foreground startUpdating()/stopUpdating() used to
    // call manager.stopUpdatingLocation() unconditionally with no reference
    // counting at all, so whichever screen happened to disappear last simply
    // turned GPS off — including out from under an unrelated screen that was
    // still using it, or (worse) out from under an active background-tracked
    // ride. activeReasons is the superset: every plain browsing reason PLUS
    // every backgroundUpdateReasons entry (requestBackgroundUpdates/
    // releaseBackgroundUpdates keep both sets in sync). The hardware only
    // actually stops once activeReasons is empty.
    private var activeReasons: Set<String> = []

    // Aug 27, 2026 — accuracy tiering (Grok battery/perf audit, fix #3). Only
    // these reasons represent the rider actually being actively tracked for
    // navigation or safety purposes — an in-progress ride, an active Need Help
    // broadcast, or crash-detection monitoring. Every other reason (browsing
    // the map, the weather widget, the Friends map, just having a screen open
    // without anything active) only ever needs a coarse fix to show "roughly
    // here" — there's no reason to keep the GPS radio pinned to
    // BestForNavigation, and the battery draw that comes with it, just because
    // one of those screens happens to be on screen.
    private static let navigationGradeReasons: Set<String> = ["rideTracking", "needHelp", "crashDetection", "lapTracking"]

    private override init() {
        super.init()
        manager.delegate = self
        applyAccuracyTier()
        manager.allowsBackgroundLocationUpdates = false
    }

    // MARK: - Permissions
    func requestPermission() {
        if manager.authorizationStatus == .notDetermined {
            manager.requestAlwaysAuthorization()
        } else if manager.authorizationStatus == .authorizedWhenInUse {
            manager.requestAlwaysAuthorization()
        }
    }

    // MARK: - Basic updates (for maps, showing location)
    // Reference-counted like requestBackgroundUpdates below — every caller
    // passes its own reason string, and the hardware only stops once nothing
    // is left holding one. A screen's stopUpdating(reason:) can never kill
    // GPS out from under some other screen (or an active background-tracked
    // ride) that's still using it.
    func startUpdating(reason: String) {
        activeReasons.insert(reason)
        applyAccuracyTier()
        manager.startUpdatingLocation()
    }

    func stopUpdating(reason: String) {
        activeReasons.remove(reason)
        applyAccuracyTier()
        if activeReasons.isEmpty {
            manager.stopUpdatingLocation()
        }
    }

    // MARK: - Background updates (reference-counted — see backgroundUpdateReasons above)
    func requestBackgroundUpdates(reason: String) {
        activeReasons.insert(reason)
        backgroundUpdateReasons.insert(reason)
        applyBackgroundUpdateSettings()
        applyAccuracyTier()
        manager.startUpdatingLocation()
    }

    func releaseBackgroundUpdates(reason: String) {
        activeReasons.remove(reason)
        backgroundUpdateReasons.remove(reason)
        applyBackgroundUpdateSettings()
        applyAccuracyTier()
        if activeReasons.isEmpty {
            manager.stopUpdatingLocation()
        }
    }

    private func applyBackgroundUpdateSettings() {
        let shouldEnable = !backgroundUpdateReasons.isEmpty
        // Without an activityType hint, iOS defaults to a much more conservative
        // background power-management profile and can throttle location updates
        // to almost nothing while the app is backgrounded — even with Always
        // authorization and Background Modes correctly configured. This tells
        // iOS what kind of background tracking to actually expect and keep
        // delivering for.
        if shouldEnable { manager.activityType = .automotiveNavigation }
        manager.allowsBackgroundLocationUpdates = shouldEnable
        manager.showsBackgroundLocationIndicator = shouldEnable
        manager.pausesLocationUpdatesAutomatically = !shouldEnable
    }

    // Aug 27, 2026 — recomputed every time activeReasons changes (any screen
    // starting/stopping/backgrounding) rather than set once at init, so the GPS
    // radio automatically steps up to navigation-grade the instant an
    // active-tracking reason joins the set, and steps back down to a coarse,
    // battery-friendly fix the instant it's released — e.g. Map + Weather both
    // open at a coarse fix, then starting a ride steps accuracy up, then ending
    // the ride (with Map still open) steps it back down instead of staying
    // pinned at BestForNavigation for the rest of the session.
    // Aug 27, 2026 — Grok Track Mode audit fix #3: "lapTracking" gets an even
    // tighter 3m filter than the other navigation-grade reasons — lap timing
    // cares about denser samples right near the start/finish line (see
    // LapEngine's crossing interpolation) in a way a street ride doesn't, so
    // it's checked first and wins if it's active alongside anything else.
    private func applyAccuracyTier() {
        if activeReasons.contains("lapTracking") {
            manager.desiredAccuracy = kCLLocationAccuracyBestForNavigation
            manager.distanceFilter = 3
        } else if !activeReasons.isDisjoint(with: Self.navigationGradeReasons) {
            manager.desiredAccuracy = kCLLocationAccuracyBestForNavigation
            manager.distanceFilter = 5
        } else {
            manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
            manager.distanceFilter = 50
        }
    }

    // MARK: - Ride tracking (distance, speed, max speed)
    // Aug 27, 2026 — Grok Track Mode audit fix #3: reason is now a parameter
    // (defaulting to "rideTracking" so every existing solo/group ride call
    // site needs no change) so LapModeView's ActiveLapView can tag its
    // session "lapTracking" instead and get the tighter 3m filter above,
    // while still going through the same distance/speed accumulation path.
    func startTracking(reason: String = "rideTracking") {
        distance = 0; maxSpeed = 0; lastTrackingLocation = nil
        isTracking = true
        requestBackgroundUpdates(reason: reason)
    }

    func stopTracking(reason: String = "rideTracking") {
        isTracking = false
        lastTrackingLocation = nil
        lastLocationForSpeedFallback = nil
        speed = 0
        releaseBackgroundUpdates(reason: reason)
    }

    func resetTracking() {
        distance = 0; maxSpeed = 0; lastTrackingLocation = nil; lastLocationForSpeedFallback = nil
    }

    // MARK: - CLLocationManagerDelegate
    // Aug 27, 2026 — Grok polish: reject obviously bad fixes before they can
    // inflate session distance / max speed (LapEngine already gates on
    // horizontalAccuracy for crossings; this keeps the shared miles/top-speed
    // counters honest on the same bad-fix days — under trees, pit lane, etc.).
    private static let maxAcceptableHorizontalAccuracy: CLLocationAccuracy = 50
    private static let maxAcceptableStepDistance: CLLocationDistance = 150

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let loc = locations.last else { return }
        DispatchQueue.main.async {
            self.location = loc

            // loc.speed is only valid when speedAccuracy >= 0; GPS often reports -1
            // (invalid) at ride start or with a weak fix, which makes the readout
            // stick at zero. Fall back to distance/time between fixes in that case.
            let speedMph: Double
            if loc.speed >= 0 && loc.speedAccuracy >= 0 {
                speedMph = loc.speed * 2.23694
            } else if let last = self.lastLocationForSpeedFallback {
                let timeDelta = loc.timestamp.timeIntervalSince(last.timestamp)
                let distanceDelta = loc.distance(from: last)
                speedMph = timeDelta > 0 ? (distanceDelta / timeDelta) * 2.23694 : self.speed
            } else {
                speedMph = 0
            }
            self.speed = max(speedMph, 0)
            self.lastLocationForSpeedFallback = loc

            if self.isTracking {
                let accuracyOK = loc.horizontalAccuracy >= 0
                    && loc.horizontalAccuracy <= Self.maxAcceptableHorizontalAccuracy
                if accuracyOK {
                    if self.speed > self.maxSpeed { self.maxSpeed = self.speed }
                    if let last = self.lastTrackingLocation {
                        let delta = loc.distance(from: last)
                        // Drop glitch jumps the same way LapEngine's trace does —
                        // one bad 300m step shouldn't add ~0.2 mi to the HUD.
                        if delta <= Self.maxAcceptableStepDistance {
                            self.distance += delta * 0.000621371
                            self.lastTrackingLocation = loc
                        }
                        // else: keep lastTrackingLocation so the next good fix
                        // measures from the last known-good point, not the glitch.
                    } else {
                        self.lastTrackingLocation = loc
                    }
                }
            }
        }
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        DispatchQueue.main.async {
            self.authStatus = manager.authorizationStatus
        }
        // Aug 27, 2026 — Grok battery/perf audit, fix #2: this used to call
        // manager.startUpdatingLocation() directly the moment permission was
        // granted, completely bypassing activeReasons — GPS would start
        // tracked by zero reasons and only ever stop as an incidental side
        // effect of some unrelated screen's stopUpdating(reason:) later
        // finding activeReasons already empty. Permission being granted isn't
        // itself a reason to track anything: every caller of
        // requestPermission() (WeatherView, ActiveSoloRideView, etc.) already
        // pairs it with its own startUpdating(reason:)/requestBackgroundUpdates
        // (reason:) call, and CLLocationManager delivers updates to those calls
        // automatically once authorization actually comes through — so GPS now
        // only ever starts through the reason-counted path above.
    }
}
