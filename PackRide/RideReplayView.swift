import SwiftUI
import MapKit
import Combine

// MARK: - Ride Replay
// Before this task: play/pause, a restart-free forward-only ±2 points/sec
// speed adjuster (two small buttons + a "\(Int)x" readout), a slider that
// could jump to any point, a moving marker + animated camera-follow, and one
// telemetry readout row (Speed / Elevation / G-Force) — all driven off a
// hand-rolled regex GPX parse private to this file (a near-duplicate of the
// one GPXRouteMapView above it in the RideHistoryView.swift also has).
//
// Added in this pass, ported from the already-shipped React Native replay
// screen:
//  - Drag-to-scrub directly on the map (pauses playback, snaps to the
//    nearest recorded point under the finger).
//  - A "Skip Forward" button that jumps ~12% of the route ahead, playback
//    continuing if it was already running.
//  - A proper 1x/2x/4x/8x speed picker, replacing the old ±2 adjuster
//    buttons (having both a discrete picker AND a free ± adjuster would be
//    two controls for the same knob) — which speeds are offered scales with
//    how many points the ride has, see `availableSpeeds` below.
//  - A second telemetry readout row (Braking G / Acceleration G /
//    Elevation), interpolated from playback position the exact same way
//    (direct index into the parsed points, no smoothing) the existing row
//    already was.
//
// Also switched its GPX parsing from that private regex copy over to
// GPXPointParser (built earlier this session for exactly this reuse), so
// this screen gets lean angle / elapsed-time-since-start for free instead of
// needing its own fourth parser.
struct RideReplayView: View {
    let gpxFilePath: String
    let rideName: String
    let rideDate: String
    @Environment(\.dismiss) var dismiss

    @State private var trackPoints: [GPXPointSample] = []
    // Signed brake/accel G per point, same formula as
    // LapCompareEngine.deriveGForces (see GPXPointParser.signedGForces for
    // the shared implementation) — kept as a parallel array rather than
    // stored on GPXPointSample itself since it depends on point ORDER
    // within this specific parsed array, not on the point alone.
    @State private var signedGForces: [Double] = []
    @State private var currentIndex = 0
    @State private var isPlaying = false
    @State private var timer: Timer?
    // Base playback rate at 1x — matches this screen's previous default
    // (pointsPerSecond was initialized to 6). The 1x/2x/4x/8x picker below
    // multiplies this rather than replacing it outright.
    private let basePointsPerSecond: Double = 6
    @State private var speedMultiplier: Double = 1
    @State private var cameraPosition: MapCameraPosition = .automatic
    @State private var routeCoordinates: [CLLocationCoordinate2D] = []
    @State private var mapStyleIndex: Int = 1 // Standard by default

    var currentPoint: GPXPointSample? {
        guard trackPoints.indices.contains(currentIndex) else { return nil }
        return trackPoints[currentIndex]
    }
    var progress: Double {
        guard trackPoints.count > 1 else { return 0 }
        return Double(currentIndex) / Double(trackPoints.count - 1)
    }
    private var tickInterval: Double { 1.0 / (basePointsPerSecond * speedMultiplier) }

    // How many points a skip-forward jumps — roughly 12% of the route
    // (within the requested 10-15% range), at least 1 point so it's never a
    // no-op on a very short/sparse recording.
    private let skipFraction: Double = 0.12

    // Which speed multipliers are offered scales with how long the ride
    // was. GPX points are captured roughly once per location update (see
    // ActiveSoloRideView's onChange(of: locationManager.location) ->
    // gpxRecorder.capturePoint), which in practice lands close to 1 Hz, so
    // point COUNT is a reasonable stand-in for ride DURATION IN SECONDS
    // without needing to look at timestamps here. At 8x with this screen's
    // base rate (6 points/sec), a genuinely short ride would blow through
    // its entire route in a couple of seconds, which isn't a usable speed —
    // so higher multipliers only unlock once there's enough ride to make
    // them worth offering:
    //   < 180 points   (roughly under 3 minutes)  -> 1x, 2x
    //   180-599 points (roughly 3-10 minutes)      -> + 4x
    //   >= 600 points  (roughly 10+ minutes)        -> + 8x
    private var availableSpeeds: [Double] {
        switch trackPoints.count {
        case ..<180: return [1, 2]
        case 180..<600: return [1, 2, 4]
        default: return [1, 2, 4, 8]
        }
    }

    var body: some View {
        ZStack {
            MapReader { proxy in
                Map(position: $cameraPosition, interactionModes: [.pan, .zoom]) {
                    if routeCoordinates.count > 1 {
                        MapPolyline(coordinates: routeCoordinates)
                            .stroke(Color.prCoral, lineWidth: 5)
                    }
                    if currentIndex > 0 {
                        MapPolyline(coordinates: Array(trackPoints.prefix(currentIndex + 1).map { $0.coordinate }))
                            .stroke(Color.prTeal, lineWidth: 4)
                    }
                    if let pt = currentPoint {
                        Annotation("", coordinate: pt.coordinate) {
                            ZStack {
                                Circle().fill(Color.prCoral).frame(width: 26, height: 26)
                                    .shadow(color: .black.opacity(0.35), radius: 6, y: 3)
                                Circle().stroke(Color.white, lineWidth: 3).frame(width: 26, height: 26)
                            }
                        }
                    }
                }
                .mapStyle(.fromIndex(mapStyleIndex))
                .ignoresSafeArea()
                .simultaneousGesture(
                    SpatialTapGesture()
                        .onEnded { value in
                            pausePlayback()
                            guard let coordinate = proxy.convert(value.location, from: .local),
                                  let idx = GPXPointParser.nearestIndex(to: coordinate, in: trackPoints) else { return }
                            currentIndex = idx
                        }
                )
            }

            LinearGradient(
                colors: [.black.opacity(0.62), .clear],
                startPoint: .top,
                endPoint: .center
            )
            .ignoresSafeArea()
            .allowsHitTesting(false)

            VStack(spacing: 0) {
                topBar
                Spacer()
                bottomPanel
            }
        }
        .onAppear { parseGPX() }
        .onDisappear { timer?.invalidate() }
        .onChange(of: speedMultiplier) { _, _ in
            if isPlaying { startTimer() }
        }
    }

    private var topBar: some View {
        HStack(spacing: 12) {
            Button(action: { dismiss() }) {
                Image(systemName: "xmark")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundColor(.white)
                    .frame(width: 38, height: 38)
                    .background(Color.black.opacity(0.34), in: Circle())
            }

            VStack(alignment: .leading, spacing: 2) {
                Text("RIDE REPLAY")
                    .font(.system(size: 10, weight: .heavy))
                    .tracking(2.2)
                    .foregroundColor(.white.opacity(0.72))
                Text(rideName)
                    .font(.system(size: 19, weight: .bold))
                    .foregroundColor(.white)
                    .lineLimit(1)
                Text(rideDate)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.white.opacity(0.68))
            }

            Spacer()

            MapStylePickerView(selectedIndex: $mapStyleIndex)
                .scaleEffect(0.72)
                .frame(width: 156, height: 56)

            HStack(spacing: 6) {
                Circle().fill(isPlaying ? Color.prTeal : Color.white.opacity(0.45)).frame(width: 7, height: 7)
                Text(isPlaying ? "PLAYING" : "PAUSED")
                    .font(.system(size: 9, weight: .heavy))
                    .tracking(1.2)
                    .foregroundColor(.white)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(Color.black.opacity(0.34), in: Capsule())
        }
        .padding(.horizontal, 18)
        .padding(.top, 16)
    }

    private var bottomPanel: some View {
        VStack(spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("ROUTE PROGRESS")
                        .font(.system(size: 9, weight: .heavy))
                        .tracking(1.4)
                        .foregroundColor(.prMuted)
                    Text("\(Int(progress * 100))% complete")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.prInk)
                }
                Spacer()
                Text("\(currentIndex + 1) / \(max(trackPoints.count, 1))")
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundColor(.prMuted)
            }

            Slider(value: Binding(
                get: { progress },
                set: { newVal in
                    guard trackPoints.count > 1 else { return }
                    currentIndex = Int(newVal * Double(trackPoints.count - 1))
                }
            ), in: 0...1)
            .tint(.prCoral)

            HStack(spacing: 10) {
                ReplayMetric(value: currentPoint.map { MeasurementUnits.speedMph($0.speedMph) } ?? "—", unit: "", label: "SPEED")
                ReplayMetric(value: currentPoint.map { String(format: "%.0f", $0.elevation * 3.28084) } ?? "—", unit: "ft", label: "ELEVATION")
                ReplayMetric(value: currentPoint.map { String(format: "%.1f", $0.gforce) } ?? "—", unit: "G", label: "G-FORCE")
            }

            HStack(spacing: 10) {
                speedPicker
                    .frame(maxWidth: .infinity)

                Button(action: skipForward) {
                    HStack(spacing: 6) {
                        Image(systemName: "forward.fill")
                        Text("+\(Int(skipFraction * 100))%")
                    }
                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                    .foregroundColor(.prInk)
                    .padding(.horizontal, 14)
                    .frame(height: 42)
                    .background(Color.prFieldBg, in: Capsule())
                }

                Button(action: togglePlay) {
                    Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 18, weight: .bold))
                        .foregroundColor(.white)
                        .frame(width: 48, height: 48)
                        .background(Color.prCoral, in: Circle())
                }
            }
        }
        .padding(.horizontal, 18)
        .padding(.top, 12)
        .padding(.bottom, 18)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 22))
        .overlay(RoundedRectangle(cornerRadius: 22).stroke(Color.white.opacity(0.16), lineWidth: 1))
        .padding(.horizontal, 12)
        .padding(.bottom, 10)
    }

    private var speedPicker: some View {
        HStack(spacing: 6) {
            ForEach(availableSpeeds, id: \.self) { speed in
                Button(action: { speedMultiplier = speed }) {
                    Text("\(Int(speed))x")
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .foregroundColor(speedMultiplier == speed ? .white : .prMuted)
                        .frame(maxWidth: .infinity)
                        .frame(height: 34)
                        .background(speedMultiplier == speed ? Color.prCoral : Color.prFieldBg, in: Capsule())
                }
            }
        }
        .padding(4)
        .background(Color.prFieldBg.opacity(0.65), in: Capsule())
    }

    func togglePlay() {
        isPlaying.toggle()
        if isPlaying {
            if currentIndex == 0 || currentIndex == trackPoints.count - 1 { fitCameraToRoute() }
            startTimer()
        } else {
            timer?.invalidate()
        }
    }

    private func startTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: tickInterval, repeats: true) { _ in
            if currentIndex < trackPoints.count - 1 {
                currentIndex += 1
            } else {
                isPlaying = false
                timer?.invalidate()
            }
        }
    }

    private func pausePlayback() {
        guard isPlaying else { return }
        isPlaying = false
        timer?.invalidate()
    }

    // Jumps playback ~12% of the route ahead. If playback was already
    // running it just keeps going from the new position — the Timer in
    // startTimer() always increments whatever currentIndex currently is, so
    // there's nothing else to restart.
    private func skipForward() {
        guard trackPoints.count > 1 else { return }
        let skipCount = max(1, Int(Double(trackPoints.count) * skipFraction))
        currentIndex = min(trackPoints.count - 1, currentIndex + skipCount)
    }

    func parseGPX() {
        trackPoints = GPXPointParser.parse(gpxFilePath: gpxFilePath)
        signedGForces = GPXPointParser.signedGForces(trackPoints)

        // Clamp the speed picker to something this ride actually offers —
        // 1x is always in availableSpeeds so this only ever lowers it.
        if !availableSpeeds.contains(speedMultiplier) {
            speedMultiplier = availableSpeeds.first ?? 1
        }

        // Build route coordinates
        let coords = trackPoints.map { $0.coordinate }

        if coords.count > 10 {
            // Dense GPS track — use actual points
            routeCoordinates = coords
        } else if coords.count >= 2 {
            // Sparse points — fetch road-following directions
            routeCoordinates = coords // fallback to straight while loading
            buildRoadRoute(coords: coords)
        }

        fitCameraToRoute()
    }

    private func fitCameraToRoute() {
        let coordinates = routeCoordinates.isEmpty ? trackPoints.map { $0.coordinate } : routeCoordinates
        guard !coordinates.isEmpty else { return }

        var rect = MKMapRect.null
        for coordinate in coordinates {
            let mapPoint = MKMapPoint(coordinate)
            rect = rect.union(MKMapRect(x: mapPoint.x, y: mapPoint.y, width: 0, height: 0))
        }
        guard !rect.isNull else { return }

        // Reserve visual space for the replay controls below the map. The
        // route is therefore centered in the unobstructed map area rather than
        // being allowed to disappear underneath the progress/telemetry panel.
        let horizontalPad = max(rect.size.width * 0.12, 180)
        let topPad = max(rect.size.height * 0.08, 120)
        let bottomPad = max(rect.size.height * 0.40, 500)

        cameraPosition = .rect(
            MKMapRect(
                x: rect.origin.x - horizontalPad,
                y: rect.origin.y - topPad,
                width: rect.size.width + (horizontalPad * 2),
                height: rect.size.height + topPad + bottomPad
            )
        )
    }



    func buildRoadRoute(coords: [CLLocationCoordinate2D]) {
        var allRouteCoords: [CLLocationCoordinate2D] = []
        let group = DispatchGroup()

        for i in 0..<(coords.count - 1) {
            group.enter()
            let request = MKDirections.Request()
            // Aug 28, 2026 — MKMapItem(location:address:) is iOS 26+ only;
            // the MKPlacemark-based initializer works on every MapKit version.
            request.source = MKMapItem(placemark: MKPlacemark(coordinate: coords[i]))
            request.destination = MKMapItem(placemark: MKPlacemark(coordinate: coords[i + 1]))
            request.transportType = .automobile
            MKDirections(request: request).calculate { response, _ in
                if let route = response?.routes.first {
                    let routePoints = route.polyline.coordinates
                    allRouteCoords.append(contentsOf: routePoints)
                } else {
                    allRouteCoords.append(contentsOf: [coords[i], coords[i + 1]])
                }
                group.leave()
            }
        }

        group.notify(queue: .main) {
            if !allRouteCoords.isEmpty {
                self.routeCoordinates = allRouteCoords
            }
        }
    }
}

// MARK: - MKPolyline coordinate extraction
extension MKPolyline {
    var coordinates: [CLLocationCoordinate2D] {
        var coords = [CLLocationCoordinate2D](repeating: CLLocationCoordinate2D(), count: pointCount)
        getCoordinates(&coords, range: NSRange(location: 0, length: pointCount))
        return coords
    }
}

struct ReplayMetric: View {
    let value: String
    let unit: String
    let label: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(value).font(.system(size: 19, weight: .bold, design: .monospaced)).foregroundColor(.prInk)
                Text(unit).font(.system(size: 10, weight: .bold)).foregroundColor(.prMuted)
            }
            Text(label).font(.system(size: 8, weight: .heavy)).tracking(1.1).foregroundColor(.prMuted)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Color.prFieldBg.opacity(0.82), in: RoundedRectangle(cornerRadius: 14))
    }
}
