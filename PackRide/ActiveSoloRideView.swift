import SwiftUI
import MapKit
import CoreLocation
import CoreMotion
import FirebaseDatabase

struct ActiveSoloRideView: View {
    @AppStorage("riderName") var riderName: String = "Rider"
    @AppStorage("nearbyRadiusMiles") private var nearbyRadiusMiles: Double = 1
    @Binding var isPresented: Bool
    @Binding var distance: Double
    @Binding var maxSpeed: Double
    @Binding var duration: String
    @Binding var gpxFilePath: String?
    @Binding var maxLeanAngle: Double
    // Set once, before the ride starts, from the share sheet in SoloRideView —
    // which of this rider's communities (if any) they opted to share name +
    // live location with for this ride. Empty by default so any other call
    // site that doesn't pass it explicitly stays opt-out-safe. Aug 21, 2026 —
    // pluralized from a single `shareWithCommunity: Bool` now that a device
    // can belong to more than one community (CommunityMembershipStore).
    var sharedCommunityIDs: Set<String> = []

    // Aug 22, 2026 — read-only here, just to turn sharedCommunityIDs (the IDs
    // chosen in SoloRideView's share sheet) into names for the "Sharing
    // with" pill below. Without any on-screen confirmation, a rider had no
    // way to tell whether community sharing was actually doing anything —
    // the location WAS already being written correctly (updateCommunityLocation
    // below), the community's own "Riding Now" + View Map already showed it
    // to OTHER members, but the person actually riding had zero feedback.
    @EnvironmentObject private var communityStore: CommunityMembershipStore
    @ObservedObject private var locationManager = SharedLocationManager.shared
    // Aug 27, 2026 — Grok battery/perf audit, fix #7: this used to be its own
    // private UserProfileManager() — a THIRD copy of that class alongside
    // PackRideApp's app-wide instance (injected as an environment object,
    // see PackRideApp.swift) and CrashDetectionView's own. Its own follow
    // requests / followed-users listeners would never see what the shared
    // instance already knew (and vice versa), and it duplicated Firebase
    // reads the shared instance was already making. Now reads the same
    // shared instance every other screen uses.
    @EnvironmentObject private var profileManager: UserProfileManager
    @StateObject private var gpxRecorder = GPXRecorder()
    @StateObject private var roadInfo = RoadInfoManager()
    @State private var cameraPosition: MapCameraPosition = .userLocation(fallback: .region(
        MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: 37.3318, longitude: -122.0312),
            span: MKCoordinateSpan(latitudeDelta: 0.02, longitudeDelta: 0.02)
        )
    ))
    @State private var elapsedTime: Int = 0
    @State private var timer: Timer?
    @State private var currentGForce: Double = 1.0
    @State private var maxGForce: Double = 1.0
    @State private var currentLeanAngle: Double = 0
    @State private var maxLeanAngleLocal: Double = 0
    @State private var leanZeroOffset: Double = 0
    @State private var leanCalibrated: Bool = false
    // Aug 24, 2026 — samples collected toward leanZeroOffset while
    // calibrating (see startLeanAngleMonitoring below), and a flag mirroring
    // that ~1s window so the HUD can show it via LeanCalibrationBadge. True
    // by default since a fresh view instance genuinely hasn't calibrated yet.
    @State private var leanCalibrationSamples: [Double] = []
    @State private var isLeanCalibrating: Bool = true
    @State private var showEndAlert = false
    @State private var selectedNearbyRider: RiderProfile? = nil
    @State private var nearbyAlertVisible = false
    @State private var mapStyleIndex = 2 // Hybrid by default so street names are visible
    @State private var rideStarted = false
    @State private var lastPublishedLocation: CLLocation?
    @State private var lastLocationPublishDate: Date?
    @State private var rideStartDate: Date?
    private let motionManager = CMMotionManager()
    // Aug 27, 2026 — Grok re-review, general issue #2: both motion callbacks
    // below used to deliver `to: .main`. Every value either touches is
    // @State (drives the live G-force/lean HUD), so the bodies still hop
    // back to DispatchQueue.main.async to do the actual work; the win is
    // CoreMotion's own delivery no longer running synchronously on the main
    // run loop, only an async enqueue onto it.
    private let motionQueue: OperationQueue = {
        let q = OperationQueue()
        q.name = "com.packride.soloRide.motion"
        q.maxConcurrentOperationCount = 1
        q.qualityOfService = .utility
        return q
    }()

    var myInitials: String { riderName.rideInitials }

    var formattedTime: String {
        let h = elapsedTime / 3600
        let m = (elapsedTime % 3600) / 60
        let s = elapsedTime % 60
        return String(format: "%02d:%02d:%02d", h, m, s)
    }

    var sharedCommunityNames: [String] {
        guard !sharedCommunityIDs.isEmpty else { return [] }
        return communityStore.myCommunities.filter { sharedCommunityIDs.contains($0.id) }.map { $0.name }
    }

    var gForceColor: Color {
        if currentGForce < 1.5 { return Color(red: 0.180, green: 0.620, blue: 0.357) }
        if currentGForce < 2.5 { return .prCoral }
        return Color(red: 0.827, green: 0.231, blue: 0.173)
    }

    var body: some View {
        ZStack(alignment: .top) {
            Map(position: $cameraPosition) {
                UserAnnotation()
                ForEach(profileManager.nearbyRiders) { rider in
                    Annotation(rider.name, coordinate: rider.coordinate, anchor: .bottom) {
                        NearbyRiderPin(rider: rider)
                            .onTapGesture { selectedNearbyRider = rider }
                    }
                }
            }
            .mapStyle(.fromIndex(mapStyleIndex))
            .ignoresSafeArea()

            VStack(spacing: 0) {
                topOverlay
                Spacer()
                if nearbyAlertVisible, let alert = profileManager.newNearbyRiderAlert {
                    nearbyAlertBanner(rider: alert)
                }
                bottomOverlay
            }
        }
        .alert("End Ride?", isPresented: $showEndAlert) {
            Button("End Ride", role: .destructive) { endRide() }
            Button("Keep Riding", role: .cancel) {}
        } message: {
            Text("You'll see a summary of your ride stats.")
        }
        .sheet(item: $selectedNearbyRider) { rider in
            NearbyRiderProfileSheet(rider: rider, profileManager: profileManager)
        }
        .onChange(of: profileManager.newNearbyRiderAlert?.id) { _, _ in
            if profileManager.newNearbyRiderAlert != nil {
                withAnimation { nearbyAlertVisible = true }
                DispatchQueue.main.asyncAfter(deadline: .now() + 8) {
                    withAnimation { nearbyAlertVisible = false }
                }
            }
        }
        .onChange(of: locationManager.location) { _, loc in
            if let loc = loc {
                // Aug 27, 2026 — Grok battery/perf audit, fix #6: listenForNearbyRiders
                // and snapshotProgress used to fire on every single GPS callback
                // (as often as once per distanceFilter's few meters of movement),
                // including a UserDefaults write + forced synchronize() on every
                // fix. They now share the same shouldPublishLocation throttle
                // already gating the Firebase location publish below, instead of
                // running unthrottled. gpxRecorder.capturePoint and roadInfo.update
                // stay outside this gate on purpose — they already self-throttle
                // internally (~1/sec, and 150m/20s respectively) at a cadence
                // tuned to their own job, and gating them further would visibly
                // degrade ride-track resolution and road-name freshness.
                let shouldPublish = shouldPublishLocation(loc)
                if shouldPublish {
                    profileManager.updateMyLocation(location: loc)
                    updateCommunityLocation(loc)
                    profileManager.listenForNearbyRiders(myLocation: loc, radiusMiles: nearbyRadiusMiles)
                    snapshotProgress()
                }
                gpxRecorder.capturePoint(location: loc)
                roadInfo.update(for: loc)
            }
        }
        .onAppear { startRide() }
        .onDisappear {
            if rideStarted {
                stopRideServices()
                gpxRecorder.cancelRecording()
            }
        }
    }

    // MARK: - Top Overlay (Speed)
    private var topOverlay: some View {
        VStack(spacing: 0) {
            HStack {
                HStack(spacing: 6) {
                    Circle().fill(Color(red: 0.827, green: 0.231, blue: 0.173)).frame(width: 8, height: 8)
                    Text("LIVE").font(.system(size: 11, weight: .bold)).foregroundColor(.white).tracking(2)
                }
                .padding(.horizontal, 10).padding(.vertical, 5)
                .background(Color.black.opacity(0.5)).cornerRadius(12)

                Spacer()

                MapStylePickerView(selectedIndex: $mapStyleIndex)

                Text(formattedTime)
                    .font(.system(size: 14, weight: .semibold, design: .monospaced))
                    .foregroundColor(.white)
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .background(Color.black.opacity(0.5)).cornerRadius(10)
            }
            .padding(.horizontal, 16).padding(.top, 50)

            if !sharedCommunityNames.isEmpty {
                HStack(spacing: 6) {
                    Image(systemName: "location.fill.viewfinder").font(.system(size: 10, weight: .bold))
                    Text("Sharing live with \(sharedCommunityNames.joined(separator: ", "))")
                        .font(.system(size: 11, weight: .semibold))
                }
                .foregroundColor(.white)
                .padding(.horizontal, 12).padding(.vertical, 6)
                .background(Color(red: 0.180, green: 0.620, blue: 0.357).opacity(0.85))
                .cornerRadius(12)
                .padding(.top, 8)
            }

            if let road = roadInfo.roadName {
                RoadNamePill(roadName: road)
                    .padding(.top, 10)
            }

            // Aug 24, 2026 — see LeanCalibrationBadge.swift's header. Answers
            // Karthik's "how does the rider know it's calibrated to 0?"
            LeanCalibrationBadge(isCalibrating: isLeanCalibrating)

            ZStack {
                VStack(spacing: 2) {
                    Text(String(format: "%.0f", locationManager.speed))
                        .font(.system(size: 80, weight: .heavy, design: .monospaced))
                        .foregroundColor(.white)
                        .shadow(color: .black.opacity(0.5), radius: 4)
                    Text("MPH")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(.white.opacity(0.9)).tracking(3)
                        .shadow(color: .black.opacity(0.5), radius: 2)
                }

                if let limit = roadInfo.speedLimitMph {
                    HStack {
                        Spacer()
                        SpeedLimitBadge(limitMph: limit, currentSpeed: locationManager.speed)
                            .padding(.trailing, 18)
                    }
                }
            }
            .padding(.top, 14)
        }
    }

    // MARK: - Bottom Overlay (Stats + End)
    private var bottomOverlay: some View {
        VStack(spacing: 14) {
            HStack(spacing: 10) {
                VStack(spacing: 3) {
                    Text(String(format: "%.1fG", currentGForce))
                        .font(.system(size: 18, weight: .bold, design: .monospaced))
                        .foregroundColor(gForceColor)
                    Text("G-Force").font(.system(size: 10)).foregroundColor(.white.opacity(0.5))
                }
                .frame(maxWidth: .infinity).padding(.vertical, 10)
                .background(Color.black.opacity(0.4)).cornerRadius(12)

                VStack(spacing: 3) {
                    Text(String(format: "%.1f", locationManager.distance))
                        .font(.system(size: 18, weight: .bold, design: .monospaced))
                        .foregroundColor(.white)
                    Text("Miles").font(.system(size: 10)).foregroundColor(.white.opacity(0.5))
                }
                .frame(maxWidth: .infinity).padding(.vertical, 10)
                .background(Color.black.opacity(0.4)).cornerRadius(12)

                VStack(spacing: 3) {
                    Text(String(format: "%.0f", locationManager.maxSpeed))
                        .font(.system(size: 18, weight: .bold, design: .monospaced))
                        .foregroundColor(.white)
                    Text(MeasurementUnits.current == .metric ? "Top km/h" : "Top mph").font(.system(size: 10)).foregroundColor(.white.opacity(0.5))
                }
                .frame(maxWidth: .infinity).padding(.vertical, 10)
                .background(Color.black.opacity(0.4)).cornerRadius(12)
            }
            .padding(.horizontal, 16)

            Button(action: { showEndAlert = true }) {
                HStack(spacing: 10) {
                    Image(systemName: "stop.circle.fill").font(.system(size: 22))
                    Text("End Ride").font(.system(size: 17, weight: .bold))
                }
                .foregroundColor(.white).frame(maxWidth: .infinity)
                .padding(.vertical, 16)
                .background(Color(red: 0.827, green: 0.231, blue: 0.173))
                .cornerRadius(16)
                .padding(.horizontal, 16)
            }
            .padding(.bottom, 30)
        }
    }

    // MARK: - Nearby Rider Banner
    private func nearbyAlertBanner(rider: RiderProfile) -> some View {
        HStack(spacing: 12) {
            ZStack {
                Circle().fill(Color.prCoral).frame(width: 38, height: 38)
                Text(rider.initials).font(.system(size: 12, weight: .bold)).foregroundColor(.white)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text("Rider nearby!").font(.system(size: 13, weight: .bold)).foregroundColor(.white)
                Text("\(rider.name) is in your vicinity. Want to grow the community?")
                    .font(.system(size: 11)).foregroundColor(.white.opacity(0.85)).lineLimit(2)
            }
            Spacer()
            Button(action: { withAnimation { nearbyAlertVisible = false } }) {
                Image(systemName: "xmark").font(.system(size: 12)).foregroundColor(.white.opacity(0.6))
            }
        }
        .padding(12).background(Color.black.opacity(0.75)).cornerRadius(14)
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.prCoral, lineWidth: 1))
        .padding(.horizontal, 16).padding(.bottom, 12)
        .onTapGesture { selectedNearbyRider = rider; nearbyAlertVisible = false }
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }

    // MARK: - Ride Lifecycle

    // Solo ride progress recovery. The actual bug behind "stats show 0" turned
    // out to be this: while riding with the app backgrounded (screen off, or
    // just switched away), iOS can and does kill the app process entirely —
    // under memory pressure, after enough background time, or because the
    // rider swiped it away in the App Switcher thinking that's how you "close"
    // an app. None of that is something PackRide can prevent. The problem was
    // what happened next: reopening the app is then a totally fresh launch —
    // every in-memory value resets, including the distance/max speed that had
    // built up in SharedLocationManager. Tapping "Record Ride" again to get
    // back to an End Ride button started a brand-new ride from zero, and
    // ending it seconds later naturally showed ~0 for everything.
    // Fix: distance/max speed/start time get snapshotted to UserDefaults on
    // every GPS fix while riding (see snapshotProgress() below), and picked
    // back up here if a ride was left mid-flight, instead of being wiped.
    private static let kActiveKey = "pr_soloRideActive"
    private static let kDistanceKey = "pr_soloRideDistance"
    private static let kMaxSpeedKey = "pr_soloRideMaxSpeed"
    private static let kStartKey = "pr_soloRideStart"

    private func snapshotProgress() {
        let d = UserDefaults.standard
        d.set(true, forKey: Self.kActiveKey)
        d.set(locationManager.distance, forKey: Self.kDistanceKey)
        d.set(locationManager.maxSpeed, forKey: Self.kMaxSpeedKey)
        // .synchronize() is officially deprecated/a no-op per Apple's docs, but
        // in practice it still forces an immediate flush attempt rather than
        // waiting for the OS's normal (undocumented, not-guaranteed-fast) write
        // cycle. Cheap enough to call every fix given this only runs a few times
        // a minute, and it directly targets the failure mode we're chasing: a
        // hard kill happening before a "soft" write ever reaches disk.
        d.synchronize()
    }

    private func clearProgress() {
        let d = UserDefaults.standard
        d.removeObject(forKey: Self.kActiveKey)
        d.removeObject(forKey: Self.kDistanceKey)
        d.removeObject(forKey: Self.kMaxSpeedKey)
        d.removeObject(forKey: Self.kStartKey)
    }

    func startRide() {
        guard !rideStarted else { return }
        rideStarted = true
        lastPublishedLocation = nil
        lastLocationPublishDate = nil
        // Location permission is normally only ever requested opportunistically
        // (e.g. from the weather widget), which tends to leave the app stuck on
        // "While Using the App." That's fine in the foreground, but GPS updates
        // stop the instant the screen locks — exactly when an actual ride needs
        // them most. Asking again right here, at the moment a ride starts, is
        // what actually triggers iOS's "Change to Always Allow?" upgrade prompt
        // if the user is currently only authorized "When In Use."
        locationManager.requestPermission()
        locationManager.resetTracking()
        locationManager.startTracking()

        // Only resume if a leftover ride marker exists AND it's recent (under
        // 6 hours old) — an old/stale marker (e.g. from a ride that genuinely
        // ended days ago some other way) should never bleed into a new ride.
        let d = UserDefaults.standard
        let savedStart = d.object(forKey: Self.kStartKey) as? Date
        if d.bool(forKey: Self.kActiveKey), let savedStart, Date().timeIntervalSince(savedStart) < 6 * 3600 {
            locationManager.distance = d.double(forKey: Self.kDistanceKey)
            locationManager.maxSpeed = d.double(forKey: Self.kMaxSpeedKey)
            rideStartDate = savedStart
            elapsedTime = Int(Date().timeIntervalSince(savedStart))
        } else {
            rideStartDate = Date()
            elapsedTime = 0
            d.set(rideStartDate, forKey: Self.kStartKey)
        }
        d.set(true, forKey: Self.kActiveKey)
        d.synchronize()

        profileManager.publishProfile(name: riderName, bike: "", city: "", experience: "")
        setCommunityRidingStatus(true)
        gpxRecorder.startRecording(rideName: "\(riderName)_Solo")
        maxLeanAngleLocal = 0
        leanCalibrated = false
        // Aug 24, 2026 — reset alongside leanCalibrated so a restarted ride
        // re-runs the full averaging window (see startLeanAngleMonitoring)
        // instead of reusing stale samples or leaving the badge stuck hidden.
        leanCalibrationSamples = []
        isLeanCalibrating = true
        timer?.invalidate()
        // Re-derives elapsedTime from the wall-clock start time on every tick
        // rather than just incrementing a counter. A plain incrementing counter
        // stops advancing while the app is backgrounded/suspended (normal during
        // an actual ride with the phone locked), which under-counts the ride's
        // real duration. Recomputing from `rideStartDate` self-corrects the
        // instant the timer resumes firing after the app comes back to the
        // foreground, instead of staying stuck at whatever it missed.
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
            if let start = rideStartDate {
                elapsedTime = Int(Date().timeIntervalSince(start))
            } else {
                elapsedTime += 1
            }
        }
        startGForceMonitoring()
        startLeanAngleMonitoring()
    }

    func endRide() {
        // Save values BEFORE stopping (stopTracking can affect Published values).
        // Duration is computed straight from rideStartDate rather than from
        // formattedTime/elapsedTime, since the on-screen timer can be behind if
        // the ride was ended right as the app returned from the background —
        // this guarantees an accurate final duration regardless of missed ticks.
        let finalDistance = locationManager.distance
        let finalMaxSpeed = locationManager.maxSpeed
        let elapsedSeconds = rideStartDate.map { Int(Date().timeIntervalSince($0)) } ?? elapsedTime
        let finalDuration = Self.formatDuration(elapsedSeconds)
        let finalGPX = gpxRecorder.stopAndSave()
        let finalMaxLean = maxLeanAngleLocal

        stopRideServices()
        clearProgress()

        distance = finalDistance
        maxSpeed = finalMaxSpeed
        duration = finalDuration
        gpxFilePath = finalGPX
        maxLeanAngle = finalMaxLean
        isPresented = false
    }

    private func stopRideServices() {
        locationManager.stopTracking()
        profileManager.goOffline()
        profileManager.stopNearbyRiderDetection()
        setCommunityRidingStatus(false)
        stopGForceMonitoring()
        stopLeanAngleMonitoring()
        timer?.invalidate()
        timer = nil
        rideStarted = false
        rideStartDate = nil
    }

    // MARK: - Lean Angle
    // Uses CoreMotion's device motion (attitude.roll), separate from the raw
    // accelerometer stream that drives G-force above — device motion is
    // sensor-fused (accelerometer + gyroscope) and gives a much steadier
    // attitude reading, which is what an actual lean estimate needs. This is a
    // phone-sensor estimate, not a calibrated instrument: it assumes the phone
    // is mounted upright relative to the bike and calibrates out whatever tilt
    // the mount itself has by treating the very first reading (bike presumably
    // still upright at ride start) as "zero," then measuring lean relative to
    // that — rather than relying on the phone being perfectly level in the
    // mount, which it usually isn't.
    // Aug 24, 2026 — leanZeroOffset used to be locked from a single reading
    // taken the instant tracking started, which is right as the rider's hand
    // is still leaving the Start button — a moment as likely as any to catch
    // some tap/hand motion rather than the phone actually settled on its
    // mount. Averaging leanCalibrationSampleCount consecutive readings
    // (~1s at the 0.2s/5Hz interval below) before locking the zero point in
    // smooths out exactly that kind of momentary jostle.
    private static let leanCalibrationSampleCount = 5

    private func startLeanAngleMonitoring() {
        guard motionManager.isDeviceMotionAvailable else { return }
        motionManager.deviceMotionUpdateInterval = 0.2
        motionManager.startDeviceMotionUpdates(to: motionQueue) { motion, _ in
            guard let motion else { return }
            let rollDegrees = motion.attitude.roll * 180 / .pi
            DispatchQueue.main.async {
                if !leanCalibrated {
                    leanCalibrationSamples.append(rollDegrees)
                    guard leanCalibrationSamples.count >= Self.leanCalibrationSampleCount else {
                        return // still settling — currentLeanAngle stays at its default 0
                    }
                    leanZeroOffset = leanCalibrationSamples.reduce(0, +) / Double(leanCalibrationSamples.count)
                    leanCalibrated = true
                    isLeanCalibrating = false
                }
                // Clamped to a realistic street-riding range. Uncapped, this reads
                // literally whatever the phone's roll is relative to its start-of-ride
                // orientation — fine on an actual bike (rarely exceeds ~50-60° even
                // riding aggressively), but meaningless if the phone isn't mounted
                // upright on a motorcycle the whole time (e.g. carried by hand while
                // walking, which easily swings past 90° and produces numbers like
                // -110° that no real lean ever would).
                let rawLean = rollDegrees - leanZeroOffset
                let lean = max(-65, min(65, rawLean))
                currentLeanAngle = lean
                gpxRecorder.currentLeanAngle = lean
                if abs(lean) > abs(maxLeanAngleLocal) { maxLeanAngleLocal = lean }
            }
        }
    }

    private func stopLeanAngleMonitoring() {
        motionManager.stopDeviceMotionUpdates()
    }

    static func formatDuration(_ seconds: Int) -> String {
        let h = seconds / 3600
        let m = (seconds % 3600) / 60
        let s = seconds % 60
        return String(format: "%02d:%02d:%02d", h, m, s)
    }

    // Flips `isRiding` on this device's membership record in every community
    // it opted to share with, if any. Kept as a direct, lightweight write
    // here (rather than spinning up a full CommunityManager per community,
    // which would also open extra realtime listeners for the duration of the
    // ride) — a Cloud Function watches this exact field to notify each
    // community when someone starts riding. See
    // PackRide_Handover_Document.md → "Push Notifications".
    //
    // Only ever touches the communities in `sharedCommunityIDs` (the share
    // sheet in SoloRideView) — both turning riding ON and turning it back OFF
    // at ride end target the same fixed set chosen at ride start, so a
    // community never ends up stuck thinking someone's still riding, and a
    // community NOT selected is never touched at all.
    private func setCommunityRidingStatus(_ isRiding: Bool) {
        guard !sharedCommunityIDs.isEmpty else { return }
        let deviceID = UIDevice.current.identifierForVendor?.uuidString ?? ""
        guard !deviceID.isEmpty else { return }
        let db = Database.database().reference()
        for communityID in sharedCommunityIDs {
            db.child("communities").child(communityID).child("members").child(deviceID)
                .updateChildValues(["isRiding": isRiding, "lastSeen": Date().timeIntervalSince1970])
        }
    }

    // Pushes real coordinates (throttled by the same shouldPublishLocation
    // gate as the Follow/Feed location update) to every shared community, so
    // each one's "Riding Now" list and Community Map actually show where a
    // sharing rider is, instead of the 0,0 they'd otherwise be stuck showing —
    // isRiding alone was already wired up to trigger the community push
    // notification, but nothing was ever populating a real position to go
    // with it.
    private func updateCommunityLocation(_ location: CLLocation) {
        guard !sharedCommunityIDs.isEmpty else { return }
        let deviceID = UIDevice.current.identifierForVendor?.uuidString ?? ""
        guard !deviceID.isEmpty else { return }
        let db = Database.database().reference()
        for communityID in sharedCommunityIDs {
            db.child("communities").child(communityID).child("members").child(deviceID)
                .updateChildValues([
                    "latitude": location.coordinate.latitude,
                    "longitude": location.coordinate.longitude,
                    "speed": locationManager.speed,
                    "lastSeen": Date().timeIntervalSince1970
                ])
        }
    }

    private func shouldPublishLocation(_ location: CLLocation) -> Bool {
        let now = Date()
        guard let lastPublishedLocation, let lastLocationPublishDate else {
            self.lastPublishedLocation = location
            self.lastLocationPublishDate = now
            return true
        }

        let shouldPublish = now.timeIntervalSince(lastLocationPublishDate) >= 5 || location.distance(from: lastPublishedLocation) >= 25
        if shouldPublish {
            self.lastPublishedLocation = location
            self.lastLocationPublishDate = now
        }
        return shouldPublish
    }

    func startGForceMonitoring() {
        guard motionManager.isAccelerometerAvailable else { return }
        motionManager.accelerometerUpdateInterval = 0.1
        motionManager.startAccelerometerUpdates(to: motionQueue) { data, _ in
            guard let data = data else { return }
            let g = sqrt(data.acceleration.x * data.acceleration.x +
                         data.acceleration.y * data.acceleration.y +
                         data.acceleration.z * data.acceleration.z)
            DispatchQueue.main.async {
                currentGForce = g
                gpxRecorder.currentGForce = g
                if g > maxGForce { maxGForce = g }
            }
        }
    }

    func stopGForceMonitoring() {
        motionManager.stopAccelerometerUpdates()
    }
}

// MARK: - Nearby Rider Pin
struct NearbyRiderPin: View {
    let rider: RiderProfile
    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                Circle().fill(Color.prTeal).frame(width: 36, height: 36)
                Text(rider.initials).font(.system(size: 12, weight: .bold)).foregroundColor(.white)
            }
            Triangle().fill(Color.prTeal).frame(width: 8, height: 5)
        }
    }
}

// MARK: - Nearby Rider Profile Sheet
struct NearbyRiderProfileSheet: View {
    let rider: RiderProfile
    @ObservedObject var profileManager: UserProfileManager
    @AppStorage("riderName") var myName: String = "Rider"
    @Environment(\.dismiss) var dismiss

    var myInitials: String { myName.rideInitials }

    var followStatus: FollowStatus {
        profileManager.followStatus[rider.id] ?? .notFollowing
    }

    var body: some View {
        ZStack {
            Color.prBg.ignoresSafeArea()
            VStack(spacing: 20) {
                RoundedRectangle(cornerRadius: 3).fill(Color.prBorder)
                    .frame(width: 40, height: 5).padding(.top, 12)

                ZStack {
                    Circle().fill(Color.prCoral).frame(width: 80, height: 80)
                    Text(rider.initials).font(.system(size: 28, weight: .bold)).foregroundColor(.white)
                }

                Text(rider.name).font(.system(size: 24, weight: .bold)).foregroundColor(.prInk)

                HStack(spacing: 6) {
                    Circle().fill(Color(red: 0.180, green: 0.620, blue: 0.357)).frame(width: 7, height: 7)
                    Text("Riding nearby").font(.system(size: 13)).foregroundColor(Color(red: 0.180, green: 0.620, blue: 0.357))
                }

                VStack(spacing: 10) {
                    InfoRow(icon: "arrowtriangle.up.fill", label: "Bike", value: rider.bike)
                    InfoRow(icon: "location.fill", label: "City", value: rider.city)
                    InfoRow(icon: "star.fill", label: "Experience", value: rider.experience)
                }
                .padding(16).background(Color.prCardBg).overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.prBorder, lineWidth: 1)).cornerRadius(16).padding(.horizontal, 24)

                followButton.padding(.horizontal, 24)
                Spacer()
            }
        }
        .onAppear { profileManager.checkFollowStatus(for: rider.id) }
    }

    @ViewBuilder
    private var followButton: some View {
        switch followStatus {
        case .isMe: EmptyView()
        case .notFollowing:
            Button(action: {
                profileManager.sendFollowRequest(to: rider.id, myName: myName, myInitials: myInitials)
            }) {
                HStack(spacing: 10) {
                    Image(systemName: "person.badge.plus").font(.system(size: 18))
                    Text("Follow").font(.system(size: 17, weight: .semibold))
                }
                .foregroundColor(.white).frame(maxWidth: .infinity)
                .padding(.vertical, 16).background(Color.prCoral).cornerRadius(14)
            }
        case .requested:
            HStack(spacing: 10) {
                Image(systemName: "clock").font(.system(size: 18))
                Text("Request Sent").font(.system(size: 17, weight: .semibold))
            }
            .foregroundColor(.prCoral).frame(maxWidth: .infinity)
            .padding(.vertical, 16).background(Color.prCoralSoft).cornerRadius(14)
        case .following:
            HStack(spacing: 10) {
                Image(systemName: "checkmark.circle.fill").font(.system(size: 18)).foregroundColor(Color(red: 0.180, green: 0.620, blue: 0.357))
                Text("Following").font(.system(size: 17, weight: .semibold)).foregroundColor(Color(red: 0.180, green: 0.620, blue: 0.357))
            }
            .frame(maxWidth: .infinity).padding(.vertical, 16)
            .background(Color(red: 0.891, green: 0.965, blue: 0.918)).cornerRadius(14)
        }
    }
}
