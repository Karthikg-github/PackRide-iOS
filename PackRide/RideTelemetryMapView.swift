import SwiftUI
import MapKit
import Combine

// MARK: - Ride Telemetry Map (tap-to-inspect)
// Full-route view of a single recorded ride where the rider can inspect
// Speed, Lean Angle, Braking G, Acceleration G, or Elevation at any point
// along the actual GPX track — ported from the already-shipped React Native
// version's telemetry map screen. Reuses GPXPointParser (built earlier this
// session specifically so this screen wouldn't need its own third GPX
// parser) for every point, and matches RideHistoryView.GPXRouteMapView /
// RideFeedView.FeedRouteMapView's "static full-route map fit to bounds"
// idea, though here it's built with SwiftUI's Map + interactionModes: []
// rather than a UIKit MKMapView, to make MapReader-based tap-to-coordinate
// conversion (below) straightforward — same MapReader pattern LapModeView's
// start/finish pin placement already uses.
struct RideTelemetryMapView: View {
    let gpxFilePath: String
    let rideName: String
    let rideDate: String
    @Environment(\.dismiss) var dismiss

    @State private var points: [GPXPointSample] = []
    @State private var signedGForces: [Double] = []
    @State private var cumulativeDistanceMeters: [Double] = []
    @State private var selectedMetric: TelemetryMetric = .speed
    @State private var selectedIndex: Int? = nil
    @State private var cameraPosition: MapCameraPosition = .automatic
    @State private var mapStyleIndex: Int = 1 // Standard by default

    // MARK: - Metric

    enum TelemetryMetric: String, CaseIterable, Identifiable {
        case speed = "Speed"
        case lean = "Lean Angle"
        case brakeG = "Braking G"
        case accelG = "Acceleration G"
        case elevation = "Elevation"

        var id: String { rawValue }

        var icon: String {
            switch self {
            case .speed: return "speedometer"
            case .lean: return "angle"
            case .brakeG: return "hand.raised.fill"
            case .accelG: return "bolt.fill"
            case .elevation: return "mountain.2.fill"
            }
        }

        // Speed and Lean Angle reuse this app's own established chart
        // colors rather than inventing new ones for them:
        //  - Speed: RideTrendsView's "Top Speed" bar chart uses Color.prTeal
        //    (RideTrendsView.swift, the TrendChartCard(title: "Top Speed")
        //    BarMark's .foregroundStyle(Color.prTeal)) — the only place in
        //    the app that already colors a Speed series, so Speed matches it
        //    here exactly.
        //  - Lean Angle: grepped LapTrendsView.swift, RideTrendsView.swift,
        //    and LapCompareView.swift (which has a `.lean` metric case but
        //    colors its chart by lap-slot, i.e. colorA/colorB, not by
        //    metric) — no screen in the app colors a lean-angle series
        //    anywhere, so there's no existing convention to match. Rather
        //    than reuse prCoral (this screen's dismiss/selection accent) or
        //    prTeal (claimed by Speed above), Lean gets its own unused blue.
        // The remaining three are new metrics per this task's spec: amber
        // #FB8C00 (Braking G), green #43A047 (Acceleration G), violet
        // #8E24AA (Elevation) — chosen there to read as clearly distinct
        // from prCoral/prTeal and from each other.
        var color: Color {
            switch self {
            case .speed: return .prTeal
            case .lean: return Color(red: 0.118, green: 0.533, blue: 0.898)     // #1E88E5
            case .brakeG: return Color(red: 0.984, green: 0.549, blue: 0.0)     // #FB8C00
            case .accelG: return Color(red: 0.259, green: 0.627, blue: 0.278)   // #43A047
            case .elevation: return Color(red: 0.557, green: 0.141, blue: 0.667) // #8E24AA
            }
        }
    }

    private func metricValue(_ metric: TelemetryMetric, at index: Int) -> Double {
        guard points.indices.contains(index) else { return 0 }
        let p = points[index]
        switch metric {
        case .speed: return p.speedMph
        // Shown as magnitude, same convention LapCompareMetric.lean already
        // uses (LapCompareEngine.swift: `abs(point.sample.leanDegrees)`) —
        // this readout is about how far over the bike was leaned, not which
        // side.
        case .lean: return abs(p.leanDegrees)
        case .brakeG: return signedGForces.indices.contains(index) ? max(0, -signedGForces[index]) : 0
        case .accelG: return signedGForces.indices.contains(index) ? max(0, signedGForces[index]) : 0
        case .elevation: return p.elevation * 3.28084 // meters -> feet, same conversion GPXRouteMapView/LapCompareEngine already use
        }
    }

    private func formattedValue(_ metric: TelemetryMetric, at index: Int) -> String {
        let v = metricValue(metric, at: index)
        switch metric {
        case .speed: return MeasurementUnits.speedMph(v)
        case .lean: return String(format: "%.0f°", v)
        case .brakeG, .accelG: return String(format: "%.2fg", v)
        case .elevation: return MeasurementUnits.elevationMeters(v / 3.28084)
        }
    }

    // MARK: - Body

    var body: some View {
        ZStack {
            MapReader { proxy in
                Map(position: $cameraPosition, interactionModes: [.pan, .zoom]) {
                    if points.count > 1 {
                        MapPolyline(coordinates: points.map { $0.coordinate })
                            .stroke(selectedMetric.color, lineWidth: 5)
                    }
                    if let idx = selectedIndex, points.indices.contains(idx) {
                        Annotation("", coordinate: points[idx].coordinate) {
                            ZStack {
                                Circle().fill(selectedMetric.color).frame(width: 24, height: 24)
                                    .shadow(color: .black.opacity(0.35), radius: 5, y: 2)
                                Circle().stroke(Color.white, lineWidth: 3).frame(width: 24, height: 24)
                            }
                        }
                    }
                }
                .mapStyle(.fromIndex(mapStyleIndex))
                .ignoresSafeArea()
                .simultaneousGesture(
                    SpatialTapGesture()
                        .onEnded { value in
                            guard let coordinate = proxy.convert(value.location, from: .local) else { return }
                            selectedIndex = GPXPointParser.nearestIndex(to: coordinate, in: points)
                        }
                )
            }

            LinearGradient(
                colors: [.black.opacity(0.64), .clear],
                startPoint: .top,
                endPoint: .center
            )
            .ignoresSafeArea()
            .allowsHitTesting(false)

            VStack(spacing: 0) {
                topBar
                Spacer()
                metricPicker
                    .padding(.bottom, 10)
                readoutCard
            }
        }
        .onAppear { load() }
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
                Text("RIDE TELEMETRY")
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
                .scaleEffect(0.76)
                .frame(width: 156, height: 56)

            Text("INSPECT")
                .font(.system(size: 9, weight: .heavy))
                .tracking(1.2)
                .foregroundColor(.white)
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(selectedMetric.color.opacity(0.9), in: Capsule())
        }
        .padding(.horizontal, 18)
        .padding(.top, 16)
    }

    private var metricPicker: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 7) {
                ForEach(TelemetryMetric.allCases) { metric in
                    Button(action: {
                        withAnimation(.easeOut(duration: 0.15)) { selectedMetric = metric }
                    }) {
                        HStack(spacing: 6) {
                            Image(systemName: metric.icon).font(.system(size: 10, weight: .semibold))
                            Text(metric.rawValue).font(.system(size: 12, weight: .semibold))
                        }
                        .foregroundColor(selectedMetric == metric ? .white : .white)
                        .padding(.horizontal, 12)
                        .frame(height: 34)
                        .background(selectedMetric == metric ? metric.color : Color.black, in: Capsule())
                    }
                }
            }
            .padding(.horizontal, 14)
        }
    }

    private var readoutCard: some View {
        Group {
            if let idx = selectedIndex, points.indices.contains(idx) {
                HStack(spacing: 14) {
                    ZStack {
                        Circle().fill(selectedMetric.color.opacity(0.18)).frame(width: 44, height: 44)
                        Image(systemName: selectedMetric.icon).font(.system(size: 17, weight: .semibold)).foregroundColor(selectedMetric.color)
                    }

                    VStack(alignment: .leading, spacing: 2) {
                        Text(formattedValue(selectedMetric, at: idx))
                            .font(.system(size: 22, weight: .bold, design: .monospaced))
                            .foregroundColor(.prInk)
                        Text(selectedMetric.rawValue.uppercased())
                            .font(.system(size: 9, weight: .heavy))
                            .tracking(1.1)
                            .foregroundColor(.prMuted)
                    }

                    Spacer()

                    if cumulativeDistanceMeters.indices.contains(idx) {
                        VStack(alignment: .trailing, spacing: 2) {
                            Text(MeasurementUnits.distanceMeters(cumulativeDistanceMeters[idx]))
                                .font(.system(size: 14, weight: .bold, design: .monospaced))
                                .foregroundColor(.prInk)
                            Text("INTO RIDE")
                                .font(.system(size: 8, weight: .heavy))
                                .tracking(1)
                                .foregroundColor(.prMuted)
                        }
                    }
                }
            } else {
                HStack(spacing: 10) {
                    Image(systemName: "hand.tap.fill").font(.system(size: 13)).foregroundColor(.prMuted)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Tap the route to inspect telemetry")
                            .font(.system(size: 13, weight: .semibold)).foregroundColor(.prInk)
                        Text("Choose a metric above, then tap any point on the ride.")
                            .font(.system(size: 10, weight: .medium)).foregroundColor(.prMuted)
                    }
                    Spacer()
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 22))
        .overlay(RoundedRectangle(cornerRadius: 22).stroke(Color.white.opacity(0.18), lineWidth: 1))
        .padding(.horizontal, 12)
        .padding(.bottom, 14)
    }

    // MARK: - Load

    private func load() {
        points = GPXPointParser.parse(gpxFilePath: gpxFilePath)
        signedGForces = GPXPointParser.signedGForces(points)

        var cumulative: [Double] = []
        var running: Double = 0
        for i in points.indices {
            if i > 0 { running += points[i].distance(from: points[i - 1]) }
            cumulative.append(running)
        }
        cumulativeDistanceMeters = cumulative

        fitCameraToRoute()
    }

    // Same bounds-fit approach GPXRouteMapView.parseGPX already uses
    // (RideHistoryView.swift): center on the route's min/max lat/lng, pad
    // the span by 1.3x with a 0.01 floor so a very short/tight route still
    // gets a sane amount of surrounding context.
    private func fitCameraToRoute() {
        guard !points.isEmpty else { return }

        var rect = MKMapRect.null
        for coordinate in points.map({ $0.coordinate }) {
            let mapPoint = MKMapPoint(coordinate)
            rect = rect.union(MKMapRect(x: mapPoint.x, y: mapPoint.y, width: 0, height: 0))
        }
        guard !rect.isNull else { return }

        // The lower telemetry panel overlays the map. Give the camera additional
        // space below the route so the entire start-to-finish track sits above
        // the panel instead of having its last section hidden underneath it.
        let horizontalPad = max(rect.size.width * 0.12, 180)
        let topPad = max(rect.size.height * 0.10, 140)
        let bottomPad = max(rect.size.height * 0.42, 520)

        cameraPosition = .rect(
            MKMapRect(
                x: rect.origin.x - horizontalPad,
                y: rect.origin.y - topPad,
                width: rect.size.width + (horizontalPad * 2),
                height: rect.size.height + topPad + bottomPad
            )
        )
    }

}

#Preview {
    RideTelemetryMapView(gpxFilePath: "", rideName: "Solo Ride", rideDate: "Aug 24, 2026")
}
