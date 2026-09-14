import SwiftUI
import MapKit
import CoreMotion

// MARK: - Turn-by-Turn Navigation View
struct TurnByTurnView: View {
    let destination: CLLocationCoordinate2D
    let destinationName: String
    var waypoints: [CLLocationCoordinate2D] = []
    // Aug 24, 2026 — lets the presenting screen (WaypointsView, at both its
    // call sites) know a ride actually finished recording here, so it can
    // pop itself too and land the rider all the way back on Home instead of
    // back on Plan Route. Optional/defaulted nil so GroupRideView's and
    // MapView's existing call sites (which don't need this) are unaffected.
    var onRideRecorded: (() -> Void)? = nil

    @AppStorage("riderName") var riderName: String = "Rider"
    @StateObject private var navManager = NavigationManager()
    @ObservedObject private var locationManager = SharedLocationManager.shared
    @StateObject private var roadInfo = RoadInfoManager()
    @StateObject private var gpxRecorder = GPXRecorder()
    @State private var cameraPosition: MapCameraPosition = .userLocation(fallback: .automatic)
    @State private var showStepsList = false
    @State private var mapStyleIndex = 2 // Hybrid by default so street names are visible
    @Environment(\.dismiss) var dismiss

    // Aug 24, 2026 — Navigate now records a real ride, mirroring Solo Ride
    // (SoloRideView/ActiveSoloRideView): GPXRecorder + lean/G-force tracking
    // start once guidance actually begins (first time navManager.state hits
    // .navigating — NOT at screen appear, which is still just "calculating
    // route"), and the resulting GPX/stats are saved through the same
    // RideHistoryManager/RideAnalyticsEngine calls Solo Ride uses.
    @State private var isRecordingRide = false
    @State private var recordingStartDate: Date?
    @State private var currentGForce: Double = 1.0
    @State private var maxGForce: Double = 1.0
    @State private var currentLeanAngle: Double = 0
    @State private var maxLeanAngleLocal: Double = 0
    @State private var leanZeroOffset: Double = 0
    @State private var leanCalibrated: Bool = false
    // Aug 24, 2026 — samples collected toward leanZeroOffset while
    // calibrating (see startLeanAngleMonitoring below), and a flag mirroring
    // that ~1s window so the HUD can show it via LeanCalibrationBadge. True
    // by default since a fresh view instance genuinely hasn't calibrated yet
    // (also keeps the badge hidden pre-recording — see its call site below,
    // gated on isRecordingRide).
    @State private var leanCalibrationSamples: [Double] = []
    @State private var isLeanCalibrating: Bool = true
    private let motionManager = CMMotionManager()
    // Aug 27, 2026 — Grok re-review, general issue #2: both motion callbacks
    // below used to deliver `to: .main`. Delivery now goes through this
    // background queue instead — every value either callback touches is
    // @State (drives the live G-force/lean HUD), so the callback bodies
    // still hop back to DispatchQueue.main.async to do the actual work; the
    // win is CoreMotion's own delivery no longer running synchronously on
    // the main run loop, only an async enqueue onto it.
    private let motionQueue: OperationQueue = {
        let q = OperationQueue()
        q.name = "com.packride.turnByTurn.motion"
        q.maxConcurrentOperationCount = 1
        q.qualityOfService = .utility
        return q
    }()

    // "End Navigation" confirm + post-ride summary — see finishRideAndNavigation()
    @State private var showEndConfirm = false
    @State private var showSummary = false
    @State private var finalDistance: Double = 0
    @State private var finalMaxSpeed: Double = 0
    @State private var finalDuration: String = "00:00:00"
    @State private var finalGPXPath: String? = nil
    @State private var finalMaxLean: Double = 0
    @State private var finalAnalytics: RideAnalyticsSummary? = nil

    var body: some View {
        ZStack {
            // Map
            Map(position: $cameraPosition) {
                UserAnnotation()

                // Route line
                // Aug 30, 2026 — navManager now exposes one polyline per
                // leg (was a single MKPolyline? that only ever held the
                // first leg — see NavigationManager.calculateRoute) so a
                // route through a start override or multiple stops draws
                // all the way to the actual destination, not just the
                // first hop.
                ForEach(Array(navManager.routePolylines.enumerated()), id: \.offset) { _, polyline in
                    MapPolyline(polyline)
                        .stroke(Color.prCoral, lineWidth: 5)
                }

                // Destination pin
                Annotation(destinationName, coordinate: destination) {
                    ZStack {
                        Circle().fill(Color.prCoral).frame(width: 32, height: 32)
                            .shadow(color: .black.opacity(0.3), radius: 4)
                        Image(systemName: "flag.checkered")
                            .font(.system(size: 14, weight: .bold)).foregroundColor(.white)
                    }
                }

                // Next turn marker
                if let step = navManager.currentStep {
                    Annotation("", coordinate: step.coordinate) {
                        ZStack {
                            Circle().fill(Color.blue).frame(width: 24, height: 24)
                                .shadow(color: .blue.opacity(0.4), radius: 4)
                            Image(systemName: step.maneuverIcon)
                                .font(.system(size: 11, weight: .bold)).foregroundColor(.white)
                        }
                    }
                }
            }
            .mapStyle(.fromIndex(mapStyleIndex))
            .ignoresSafeArea()

            VStack(spacing: 0) {
                // Top: Turn instruction card
                instructionCard

                // Recording indicator — mirrors Solo Ride's "LIVE" pill (same
                // dot + tracked-caps-text construction), shown while this
                // navigation session is actually recording a ride.
                if isRecordingRide {
                    HStack {
                        recordingBadge
                        Spacer()
                    }
                    .padding(.horizontal, 16).padding(.top, 10)

                    // Aug 24, 2026 — see LeanCalibrationBadge.swift's header.
                    // Gated on isRecordingRide (not just isLeanCalibrating,
                    // which defaults true) since this screen is visible well
                    // before recording — and lean tracking — actually starts.
                    LeanCalibrationBadge(isCalibrating: isLeanCalibrating)
                }

                // Road name + speed limit — floats over the map, below the turn card
                HStack {
                    if let road = roadInfo.roadName {
                        RoadNamePill(roadName: road)
                    }
                    Spacer()
                    if let limit = roadInfo.speedLimitMph {
                        SpeedLimitBadge(limitMph: limit, currentSpeed: locationManager.speed)
                            .scaleEffect(0.75, anchor: .trailing)
                    }
                }
                .padding(.horizontal, 16).padding(.top, 12)

                Spacer()

                // Right: map controls
                HStack {
                    Spacer()
                    VStack(spacing: 8) {
                        MapStyleBtn(icon: "globe.americas.fill", label: "SAT", isActive: mapStyleIndex == 0) { mapStyleIndex = 0 }
                        MapStyleBtn(icon: "map.fill", label: "MAP", isActive: mapStyleIndex == 1) { mapStyleIndex = 1 }
                        MapStyleBtn(icon: "car.fill", label: "HYB", isActive: mapStyleIndex == 2) { mapStyleIndex = 2 }
                    }
                    .padding(4).background(.ultraThinMaterial).cornerRadius(14)
                    .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.white.opacity(0.1), lineWidth: 1))
                    .padding(.trailing, 16)
                }

                Spacer()

                // Bottom: stats + controls
                bottomPanel
            }
        }
        .onAppear { startNavigation() }
        .onDisappear {
            // Guard against losing an in-progress recording if this screen
            // disappears without going through "End Navigation"/arrival —
            // same belt-and-suspenders pattern as ActiveSoloRideView.onDisappear:
            // stop the services so nothing keeps running in the background,
            // and discard the GPX rather than silently saving a partial ride
            // the rider never confirmed ending.
            if isRecordingRide {
                stopRideRecordingServices()
                gpxRecorder.cancelRecording()
            }
            navManager.stopNavigation()
        }
        .onChange(of: navManager.state) { _, newState in
            // Guarded by isRecordingRide so a mid-ride reroute (.rerouting ->
            // .calculating -> .navigating again) never restarts the recording —
            // this only fires once, the first time real guidance begins.
            if newState == .navigating && !isRecordingRide {
                startRecordingRide()
            }
        }
        .onChange(of: locationManager.location) { _, loc in
            guard let loc = loc else { return }
            navManager.updatePosition(loc)
            roadInfo.update(for: loc)
            if isRecordingRide {
                gpxRecorder.capturePoint(location: loc)
            }

            // Follow user
            withAnimation(.linear(duration: 1)) {
                cameraPosition = .region(MKCoordinateRegion(
                    center: loc.coordinate,
                    span: MKCoordinateSpan(latitudeDelta: 0.008, longitudeDelta: 0.008)
                ))
            }
        }
        .sheet(isPresented: $showStepsList) { stepsListSheet }
        .alert("End Navigation?", isPresented: $showEndConfirm) {
            Button("Keep Riding", role: .cancel) {}
            Button("End Navigation", role: .destructive) { finishRideAndNavigation() }
        } message: {
            Text("Your ride is being recorded. Ending now will save it to your Ride History.")
        }
        // Presented directly from here (rather than dismissing first, like
        // SoloRideView does) since TurnByTurnView is the fullScreenCover
        // content itself at every call site (WaypointsView, GroupRideView,
        // MapView) — there's no separate "owner" screen to hand the summary
        // off to. Dismissing the summary sheet also dismisses this screen,
        // returning the rider to wherever Navigate was launched from.
        .sheet(isPresented: $showSummary, onDismiss: { dismiss() }) {
            RideSummaryView(
                distance: finalDistance, maxSpeed: finalMaxSpeed, duration: finalDuration,
                gpxFilePath: finalGPXPath, maxLeanAngle: finalMaxLean, analytics: finalAnalytics
            )
        }
    }

    // MARK: - Recording Badge
    private var recordingBadge: some View {
        HStack(spacing: 6) {
            Circle().fill(Color.prCoral).frame(width: 8, height: 8)
            Text("RECORDING RIDE")
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .foregroundColor(.white).tracking(2)
        }
        .padding(.horizontal, 10).padding(.vertical, 5)
        .background(Color.black.opacity(0.5)).cornerRadius(12)
    }

    // MARK: - Instruction Card
    private var instructionCard: some View {
        Group {
            switch navManager.state {
            case .calculating, .rerouting:
                HStack(spacing: 12) {
                    ProgressView().tint(.white)
                    Text(navManager.state == .rerouting ? "Rerouting..." : "Calculating route...")
                        .font(.system(size: 15, weight: .semibold, design: .rounded)).foregroundColor(.white)
                }
                .frame(maxWidth: .infinity).padding(.vertical, 20)
                .background(Color.prInkFixed).cornerRadius(0)

            case .navigating:
                if let step = navManager.currentStep {
                    VStack(spacing: 0) {
                        // Main instruction
                        HStack(spacing: 14) {
                            // Turn icon
                            ZStack {
                                RoundedRectangle(cornerRadius: 14)
                                    .fill(Color.prCoral)
                                    .frame(width: 56, height: 56)
                                Image(systemName: step.maneuverIcon)
                                    .font(.system(size: 24, weight: .bold))
                                    .foregroundColor(.white)
                            }

                            VStack(alignment: .leading, spacing: 4) {
                                // Distance to turn
                                Text(MeasurementUnits.distanceMeters(navManager.distanceToNextStep))
                                    .font(.system(size: 26, weight: .heavy, design: .rounded))
                                    .foregroundColor(.white)
                                    .monospacedDigit()

                                // Instruction text
                                Text(step.instruction)
                                    .font(.system(size: 14, weight: .medium, design: .rounded))
                                    .foregroundColor(.white.opacity(0.8))
                                    .lineLimit(2)
                            }

                            Spacer()
                        }
                        .padding(16)
                        .background(Color.prInkFixed)

                        // Next step preview
                        if let next = navManager.nextStep {
                            HStack(spacing: 10) {
                                Text("THEN")
                                    .font(.system(size: 9, weight: .heavy, design: .rounded))
                                    .foregroundColor(.prMuted).tracking(1.5)
                                Image(systemName: next.maneuverIcon)
                                    .font(.system(size: 12, weight: .bold)).foregroundColor(.prInk)
                                Text(next.instruction)
                                    .font(.system(size: 12, design: .rounded))
                                    .foregroundColor(.prInk).lineLimit(1)
                                Spacer()
                            }
                            .padding(.horizontal, 16).padding(.vertical, 8)
                            .background(Color.prCardBg)
                        }
                    }
                }

            case .arrived:
                HStack(spacing: 12) {
                    Image(systemName: "flag.checkered")
                        .font(.system(size: 24)).foregroundColor(.white)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("You've Arrived!")
                            .font(.system(size: 18, weight: .bold, design: .rounded)).foregroundColor(.white)
                        Text(destinationName)
                            .font(.system(size: 13, design: .rounded)).foregroundColor(.white.opacity(0.7))
                    }
                    Spacer()
                    Button(action: { finishRideAndNavigation() }) {
                        Text("Done").font(.system(size: 14, weight: .bold, design: .rounded))
                            .foregroundColor(.prCoral).padding(.horizontal, 16).padding(.vertical, 8)
                            .background(Color.prCardBg).cornerRadius(10)
                    }
                }
                .frame(maxWidth: .infinity).padding(16)
                .background(Color(red: 0.2, green: 0.7, blue: 0.4))

            case .idle:
                EmptyView()
            }
        }
    }

    // MARK: - Bottom Panel
    private var bottomPanel: some View {
        VStack(spacing: 10) {
            // Stats row
            HStack(spacing: 0) {
                VStack(spacing: 2) {
                    Text(navManager.etaString)
                        .font(.system(size: 18, weight: .bold, design: .rounded)).foregroundColor(.prInk)
                    Text("ETA").font(.system(size: 9, weight: .medium, design: .rounded)).foregroundColor(.prMuted)
                }
                .frame(maxWidth: .infinity)

                Divider().frame(height: 30)

                VStack(spacing: 2) {
                    Text(navManager.distanceRemainingString)
                        .font(.system(size: 18, weight: .bold, design: .rounded)).foregroundColor(.prInk)
                    Text("Distance").font(.system(size: 9, weight: .medium, design: .rounded)).foregroundColor(.prMuted)
                }
                .frame(maxWidth: .infinity)

                Divider().frame(height: 30)

                VStack(spacing: 2) {
                    Text(String(format: "%.0f", locationManager.speed))
                        .font(.system(size: 18, weight: .bold, design: .rounded)).foregroundColor(.prInk)
                        .monospacedDigit()
                    Text("MPH").font(.system(size: 9, weight: .medium, design: .rounded)).foregroundColor(.prMuted)
                }
                .frame(maxWidth: .infinity)
            }
            .padding(.vertical, 12)
            .background(Color.prCardBg)
            .cornerRadius(14)
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.prBorder, lineWidth: 1))

            // Control buttons
            HStack(spacing: 10) {
                // Steps list
                Button(action: { showStepsList = true }) {
                    Image(systemName: "list.bullet")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(.prInk)
                        .frame(width: 48, height: 48)
                        .background(Color.prCardBg).cornerRadius(14)
                        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.prBorder, lineWidth: 1))
                }

                // Voice toggle
                Button(action: { navManager.toggleVoice() }) {
                    Image(systemName: navManager.isVoiceEnabled ? "speaker.wave.2.fill" : "speaker.slash.fill")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(navManager.isVoiceEnabled ? .prCoral : .prMuted)
                        .frame(width: 48, height: 48)
                        .background(Color.prCardBg).cornerRadius(14)
                        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.prBorder, lineWidth: 1))
                }

                // End navigation
                Button(action: {
                    if isRecordingRide {
                        // A real recording is running — confirm before it's
                        // thrown away, same as ActiveSoloRideView's "End Ride?" alert.
                        showEndConfirm = true
                    } else {
                        navManager.stopNavigation()
                        dismiss()
                    }
                }) {
                    Text("End Navigation")
                        .font(.system(size: 15, weight: .bold, design: .rounded))
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity).frame(height: 48)
                        .background(Color.prCoral).cornerRadius(14)
                }
            }
            .padding(.bottom, 30)
        }
        .padding(.horizontal, 16)
    }

    // MARK: - Steps List Sheet
    private var stepsListSheet: some View {
        ZStack {
            Color.prBg.ignoresSafeArea()
            VStack(spacing: 0) {
                HStack {
                    Text("Route Steps")
                        .font(.system(size: 17, weight: .bold, design: .rounded)).foregroundColor(.prInk)
                    Spacer()
                    Button(action: { showStepsList = false }) {
                        Image(systemName: "xmark.circle.fill").font(.system(size: 24)).foregroundColor(.prMuted)
                    }
                }
                .padding(16)

                ScrollView {
                    VStack(spacing: 6) {
                        ForEach(Array(navManager.steps.enumerated()), id: \.element.id) { index, step in
                            HStack(spacing: 14) {
                                ZStack {
                                    Circle()
                                        .fill(index == navManager.currentStepIndex ? Color.prCoral :
                                              step.isCompleted ? Color.green : Color.prBorder)
                                        .frame(width: 36, height: 36)
                                    if step.isCompleted {
                                        Image(systemName: "checkmark")
                                            .font(.system(size: 14, weight: .bold)).foregroundColor(.white)
                                    } else {
                                        Image(systemName: step.maneuverIcon)
                                            .font(.system(size: 14, weight: .bold))
                                            .foregroundColor(index == navManager.currentStepIndex ? .white : .prInk)
                                    }
                                }

                                VStack(alignment: .leading, spacing: 3) {
                                    Text(step.instruction)
                                        .font(.system(size: 14, weight: .medium, design: .rounded))
                                        .foregroundColor(step.isCompleted ? .prMuted : .prInk)
                                        .strikethrough(step.isCompleted)
                                    Text(step.distanceString)
                                        .font(.system(size: 12, design: .rounded)).foregroundColor(.prMuted)
                                }

                                Spacer()

                                if index == navManager.currentStepIndex {
                                    Text("NOW")
                                        .font(.system(size: 9, weight: .heavy, design: .rounded))
                                        .foregroundColor(.prCoral).tracking(1.5)
                                        .padding(.horizontal, 8).padding(.vertical, 4)
                                        .background(Color.prCoral.opacity(0.1)).cornerRadius(6)
                                }
                            }
                            .padding(12).background(Color.prCardBg).cornerRadius(12)
                            .overlay(RoundedRectangle(cornerRadius: 12).stroke(
                                index == navManager.currentStepIndex ? Color.prCoral.opacity(0.3) : Color.prBorder, lineWidth: 1))
                            .padding(.horizontal, 16)
                        }
                    }
                    .padding(.bottom, 40)
                }
            }
        }
    }

    // MARK: - Start
    func startNavigation() {
        locationManager.startTracking()
        guard let loc = locationManager.location else {
            // Retry after location arrives
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { startNavigation() }
            return
        }
        navManager.calculateRoute(from: loc.coordinate, to: destination, waypoints: waypoints)
    }

    // MARK: - Ride Recording (mirrors ActiveSoloRideView.startRide/endRide)

    private func startRecordingRide() {
        guard !isRecordingRide else { return }
        isRecordingRide = true
        recordingStartDate = Date()
        // Re-starts tracking (distinct from the startTracking() call in
        // startNavigation() above, which only runs the location feed for the
        // ETA/speed HUD while a route is still being calculated) so the
        // recorded ride's distance/max-speed genuinely begin at the moment
        // guidance starts, not whenever this screen happened to appear.
        // startTracking()/stopTracking() are idempotent to call more than
        // once — see SharedLoactionManager.swift.
        locationManager.startTracking()
        gpxRecorder.startRecording(rideName: "\(riderName)_Navigate")
        maxLeanAngleLocal = 0
        leanCalibrated = false
        // Aug 24, 2026 — reset alongside leanCalibrated so re-recording (if
        // this ever restarts) re-runs the full averaging window (see
        // startLeanAngleMonitoring) instead of reusing stale samples or
        // leaving the badge stuck hidden.
        leanCalibrationSamples = []
        isLeanCalibrating = true
        startGForceMonitoring()
        startLeanAngleMonitoring()
    }

    // Called both from "End Navigation" (after confirmation) and from the
    // "Arrived" card's Done button — either way guidance is over and, if a
    // ride was recording, it gets saved through the exact same
    // RideAnalyticsEngine/RideHistoryManager calls Solo Ride uses before
    // showing the same RideSummaryView.
    private func finishRideAndNavigation() {
        navManager.stopNavigation()
        guard isRecordingRide else {
            dismiss()
            return
        }

        // Save values BEFORE stopping services (stopTracking can affect
        // Published values) — same ordering as ActiveSoloRideView.endRide().
        let finalDist = locationManager.distance
        let finalMaxSpd = locationManager.maxSpeed
        let elapsedSeconds = recordingStartDate.map { Int(Date().timeIntervalSince($0)) } ?? 0
        let finalDur = ActiveSoloRideView.formatDuration(elapsedSeconds)
        let finalGPX = gpxRecorder.stopAndSave()
        let finalLean = maxLeanAngleLocal

        stopRideRecordingServices()

        let analytics = finalGPX.flatMap { RideAnalyticsEngine.analyze(gpxFilePath: $0) }
        RideHistoryManager.recordRide(
            distance: finalDist, maxSpeed: finalMaxSpd, duration: finalDur,
            isGroupRide: false, gpxFilePath: finalGPX,
            maxLeanAngle: finalLean, analytics: analytics,
            bikeId: BikeManager.currentActiveBikeID()
        )

        finalDistance = finalDist
        finalMaxSpeed = finalMaxSpd
        finalDuration = finalDur
        finalGPXPath = finalGPX
        finalMaxLean = finalLean
        finalAnalytics = analytics
        showSummary = true
        // A real ride was just recorded (not just "closed navigation before
        // it started") — tell the presenting screen so it knows to also pop
        // itself once the summary is dismissed.
        onRideRecorded?()
    }

    private func stopRideRecordingServices() {
        locationManager.stopTracking()
        stopGForceMonitoring()
        stopLeanAngleMonitoring()
        isRecordingRide = false
        recordingStartDate = nil
    }

    // MARK: - G-Force
    private func startGForceMonitoring() {
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

    private func stopGForceMonitoring() {
        motionManager.stopAccelerometerUpdates()
    }

    // MARK: - Lean Angle
    // Same device-motion-based estimate as ActiveSoloRideView.startLeanAngleMonitoring —
    // measures lean relative to a zero point calibrated after recording
    // starts, clamped to a realistic street-riding range.
    //
    // Aug 24, 2026 — leanZeroOffset used to be locked from a single reading
    // taken the instant recording started, which is right as the rider's
    // hand is still leaving the Start button — a moment as likely as any to
    // catch some tap/hand motion rather than the phone actually settled on
    // its mount. Averaging leanCalibrationSampleCount consecutive readings
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
}
