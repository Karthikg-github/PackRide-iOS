import SwiftUI
import CoreLocation
import Combine
import FirebaseDatabase
import UIKit
import CoreMotion
import MapKit

// Aug 27, 2026 — Grok battery/perf audit, fix #1: this used to be preceded by
// its own RideLocationManager class — a second private CLLocationManager,
// entirely separate from the app-wide SharedLocationManager, duplicating the
// same distance/speed/max-speed math. It was never instantiated anywhere —
// SoloRideView below just presents ActiveSoloRideView, which already reads
// SharedLocationManager.shared directly — so it was dead code, not a second
// active GPS source. Removed rather than fixed in place.

// MARK: - Solo Ride View
struct SoloRideView: View {
    @AppStorage("riderName") var riderName: String = "Rider"
    @EnvironmentObject var communityStore: CommunityMembershipStore
    // Aug 24, 2026 — used by the showSummary sheet's onDismiss below so
    // Solo Ride pops itself once the post-ride summary is dismissed,
    // landing the rider back on Home instead of leaving them stranded on
    // this (now-idle) recording screen.
    @Environment(\.dismiss) var dismiss
    @State private var showCommunityShareSheet = false
    @State private var sharedCommunityIDs: Set<String> = []
    @State private var showActiveRide = false
    @State private var showSummary = false
    @State private var finalDistance: Double = 0
    @State private var finalMaxSpeed: Double = 0
    @State private var finalDuration: String = "00:00:00"
    @State private var finalGPXPath: String? = nil
    @State private var finalMaxLean: Double = 0
    @State private var finalAnalytics: RideAnalyticsSummary? = nil
    @State private var appeared = false
    @State private var mapStyleIndex = 2 // Hybrid by default so street names are visible
    @State private var buttonPulse = false

    @State private var cameraPosition: MapCameraPosition = .userLocation(fallback: .region(
        MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: 37.33, longitude: -122.03),
            span: MKCoordinateSpan(latitudeDelta: 0.04, longitudeDelta: 0.04)
        )
    ))

    var body: some View {
        ZStack {
            Map(position: $cameraPosition) { UserAnnotation() }
                .mapStyle(.fromIndex(mapStyleIndex))
                .ignoresSafeArea()

            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("PACKRIDE")
                            .font(.system(size: 11, weight: .heavy))
                            .tracking(2.4)
                            .foregroundColor(.white)
                        Text("SOLO RIDE")
                            .font(.system(size: 10, weight: .heavy))
                            .tracking(2)
                            .foregroundColor(.white.opacity(0.64))
                    }
                    Spacer()
                    MapStylePickerView(selectedIndex: $mapStyleIndex)
                }
                .padding(.horizontal, 20)
                .padding(.top, 14)

                Spacer()

                VStack(alignment: .leading, spacing: 14) {
                    Text("YOUR ROAD, YOUR RULES")
                        .font(.system(size: 10, weight: .heavy))
                        .tracking(2.2)
                        .foregroundColor(.white.opacity(0.62))

                    HStack(spacing: 10) {
                        PRWebLivePill(label: "GPS READY", accent: .prTeal)
                        PRWebLivePill(label: "GPX RECORDING", accent: .prCoral)
                    }

                    HStack(spacing: 0) {
                        soloPreviewMetric("SPEED", MeasurementUnits.speedMph(0))
                        Rectangle().fill(Color.white.opacity(0.12)).frame(width: 1, height: 34)
                        soloPreviewMetric("DISTANCE", MeasurementUnits.distanceMiles(0))
                        Rectangle().fill(Color.white.opacity(0.12)).frame(width: 1, height: 34)
                        soloPreviewMetric("G-FORCE", "READY")
                    }
                    .padding(.vertical, 12)
                    .background(Color.black)
                    .clipShape(RoundedRectangle(cornerRadius: 16))
                    .overlay(
                        RoundedRectangle(cornerRadius: 16)
                            .stroke(Color.white.opacity(0.16), lineWidth: 1)
                    )

                    Text("Every ride is saved as GPX with speed, elevation & G-force data")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.white.opacity(0.55))
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 14)

                Button(action: {
                    if !communityStore.myCommunities.isEmpty {
                        showCommunityShareSheet = true
                    } else {
                        sharedCommunityIDs = []
                        showActiveRide = true
                    }
                }) {
                    HStack(spacing: 12) {
                        Image(systemName: "play.fill")
                            .font(.system(size: 13, weight: .bold))
                        Text("START RIDE")
                            .font(.system(size: 16, weight: .heavy))
                            .tracking(2)
                        Spacer()
                        Image(systemName: "arrow.right")
                            .font(.system(size: 13, weight: .bold))
                    }
                    .foregroundColor(.white)
                    .padding(.horizontal, 18)
                    .frame(height: 58)
                    .background(Color.prCoral)
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 24)
            }
            .opacity(appeared ? 1 : 0)
            .offset(y: appeared ? 0 : 18)
        }
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            withAnimation(.easeOut(duration: 0.5)) { appeared = true }
            withAnimation(.easeInOut(duration: 1.5).repeatForever(autoreverses: true)) { buttonPulse = true }
        }
        .sheet(isPresented: $showCommunityShareSheet) {
            CommunityShareSheet(communities: communityStore.myCommunities) { selected in
                sharedCommunityIDs = selected
                showActiveRide = true
            }
        }
        .fullScreenCover(isPresented: $showActiveRide, onDismiss: {
            guard finalDistance > 0 else { return }
            // Analytics (ride score, cornering, hard brake/accel events) are
            // computed once here, right from the GPX file that was just saved,
            // rather than re-parsed every time Ride History is opened.
            finalAnalytics = finalGPXPath.flatMap { RideAnalyticsEngine.analyze(gpxFilePath: $0) }
            RideHistoryManager.recordRide(
                distance: finalDistance, maxSpeed: finalMaxSpeed,
                duration: finalDuration, isGroupRide: false, gpxFilePath: finalGPXPath,
                maxLeanAngle: finalMaxLean, analytics: finalAnalytics,
                bikeId: BikeManager.currentActiveBikeID()
            )
            // Presenting a new sheet immediately inside another modal's onDismiss
            // is a known SwiftUI timing issue — the fullScreenCover's own dismissal
            // transition hasn't always finished tearing down yet, so the sheet can
            // flash on screen and get killed instead of staying up. A short delay
            // lets that transition finish first.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                showSummary = true
            }
        }) {
            ActiveSoloRideView(
                isPresented: $showActiveRide, distance: $finalDistance,
                maxSpeed: $finalMaxSpeed, duration: $finalDuration, gpxFilePath: $finalGPXPath,
                maxLeanAngle: $finalMaxLean, sharedCommunityIDs: sharedCommunityIDs
            )
        }
        .sheet(isPresented: $showSummary, onDismiss: { dismiss() }) {
            RideSummaryView(
                distance: finalDistance, maxSpeed: finalMaxSpeed, duration: finalDuration,
                gpxFilePath: finalGPXPath, maxLeanAngle: finalMaxLean, analytics: finalAnalytics
            )
        }
    }
}

    private func soloPreviewMetric(_ label: String, _ value: String) -> some View {
        VStack(spacing: 3) {
            Text(value)
                .font(.system(size: 15, weight: .bold, design: .monospaced))
                .foregroundColor(.white)
            Text(label)
                .font(.system(size: 8, weight: .heavy))
                .tracking(1.1)
                .foregroundColor(.white.opacity(0.48))
        }
        .frame(maxWidth: .infinity)
    }


// MARK: - Community Share Sheet
// Aug 21, 2026 — replaces the old single "Share with My Community" Yes/No
// alert now that a device can belong to more than one community
// (CommunityMembershipStore). A plain alert can't host a multi-select list,
// so this is a small sheet instead: every joined community gets its own row,
// tap to toggle, "Continue" always proceeds to the ride with whatever's
// checked (nothing checked = don't share with anyone, same as "Don't Share"
// used to do).
struct CommunityShareSheet: View {
    let communities: [Community]
    let onConfirm: (Set<String>) -> Void
    @State private var selected: Set<String> = []
    @Environment(\.dismiss) var dismiss

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                VStack(spacing: 8) {
                    Image(systemName: "location.fill.viewfinder").font(.system(size: 30)).foregroundColor(.prCoral)
                    Text("Share Live Location?").font(.system(size: 18, weight: .bold)).foregroundColor(.prInk)
                    Text("Checked communities will be notified you started riding and can see your live location until you end your ride.")
                        .font(.system(size: 12)).foregroundColor(.prMuted).multilineTextAlignment(.center)
                }
                .padding(.horizontal, 24).padding(.top, 24).padding(.bottom, 16)

                ScrollView {
                    VStack(spacing: 10) {
                        ForEach(communities) { community in
                            Button(action: {
                                if selected.contains(community.id) { selected.remove(community.id) }
                                else { selected.insert(community.id) }
                            }) {
                                HStack(spacing: 12) {
                                    ZStack {
                                        Circle().fill(Color.prCoralSoft).frame(width: 40, height: 40)
                                        Image(systemName: "flame.fill").font(.system(size: 15)).foregroundColor(.prCoral)
                                    }
                                    Text(community.name).font(.system(size: 15, weight: .medium)).foregroundColor(.prInk)
                                    Spacer()
                                    Image(systemName: selected.contains(community.id) ? "checkmark.circle.fill" : "circle")
                                        .font(.system(size: 20))
                                        .foregroundColor(selected.contains(community.id) ? .prCoral : .prBorder)
                                }
                                .padding(14)
                                .background(Color.prCardBg)
                                .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.prBorder, lineWidth: 1))
                                .cornerRadius(14)
                            }
                        }
                    }
                    .padding(.horizontal, 20)
                }

                Button(action: { onConfirm(selected); dismiss() }) {
                    Text(selected.isEmpty ? "Don't Share — Start Ride" : "Share & Start Ride")
                        .font(.system(size: 16, weight: .bold)).foregroundColor(.white)
                        .frame(maxWidth: .infinity).padding(.vertical, 16)
                        .background(Color.prCoral).cornerRadius(16)
                }
                .padding(20)
            }
            .background(Color.prBg.ignoresSafeArea())
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Cancel") { dismiss() }.foregroundColor(.prMuted)
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

// MARK: - Feature Pill
struct FeaturePill: View {
    let icon: String
    let label: String
    let color: Color

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(color)
                .frame(width: 20)
            Text(label)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.prInk)
            Spacer()
        }
        .padding(.horizontal, 16).padding(.vertical, 14)
        .background(Color.prCardBg)
        .cornerRadius(14)
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.prBorder, lineWidth: 1))
    }
}

// MARK: - Ride Summary View
struct RideSummaryView: View {
    let distance: Double
    let maxSpeed: Double
    let duration: String
    var gpxFilePath: String? = nil
    var maxLeanAngle: Double = 0
    var analytics: RideAnalyticsSummary? = nil
    @AppStorage("riderName") var riderName: String = "Rider"
    @Environment(\.dismiss) var dismiss

    // Aug 24, 2026 — hero route map (see heroSection below). Populated
    // on-appear from the already-saved GPX file, same GPXPointParser this
    // whole pass was built around, rather than a new parser. Empty when
    // gpxFilePath is nil or the file has no usable points — heroSection
    // falls back to the original plain checkered-flag circle in that case,
    // so a ride with no GPX (or a parse failure) never breaks this screen.
    @State private var heroPoints: [GPXPointSample] = []
    @State private var heroCameraPosition: MapCameraPosition = .automatic

    private var hasHeroRoute: Bool { heroPoints.count > 1 }

    var body: some View {
        ZStack {
            Color.prBg.ignoresSafeArea()

            ScrollView {
            VStack(spacing: 28) {
                heroSection

                VStack(spacing: 4) {
                    Text("Ride Complete!")
                        .font(.system(size: 26, weight: .bold)).foregroundColor(.prInk)
                    Text("Great ride out there")
                        .font(.system(size: 13)).foregroundColor(.prMuted)
                }

                VStack(spacing: 1) {
                    ReverStatRow(leftLabel: "Dist", leftValue: MeasurementUnits.distanceMiles(distance), icon: "ruler", rightLabel: "Max", rightValue: MeasurementUnits.speedMph(maxSpeed))
                    ReverStatRow(leftLabel: "Time", leftValue: duration, icon: "clock", rightLabel: "Lean", rightValue: String(format: "%.0f°", maxLeanAngle))
                }
                .padding(.horizontal, 0)

                if let analytics {
                    RideScoreCard(analytics: analytics, maxLeanAngle: maxLeanAngle)
                        .padding(.horizontal, 16)
                }

                Text("Ride recorded to Ride History")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundColor(.red)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 2)

                Button(action: { dismiss() }) {
                    Text("Done").font(.system(size: 14, weight: .bold)).foregroundColor(.white)
                        .frame(maxWidth: .infinity).padding(.vertical, 16)
                        .background(Color.prCoral).cornerRadius(16)
                        .padding(.horizontal, 20)
                }
                Spacer().frame(height: 20)
            }
            }
        }
        .onAppear { loadHeroRoute() }
    }

    static func todayString() -> String {
        let f = DateFormatter(); f.dateFormat = "M/d/yy"
        return f.string(from: Date())
    }

    // MARK: - Hero (route map or fallback)
    // Real static route polyline + floating glass stat pill when a usable
    // GPX exists; otherwise the screen's original plain checkered-flag
    // circle, unchanged. distance/duration/maxSpeed/maxLeanAngle are all
    // reused as passed into this view — nothing here is recomputed from the
    // GPX except the polyline coordinates and the camera bounds fit.
    @ViewBuilder
    private var heroSection: some View {
        if hasHeroRoute {
            VStack(spacing: 12) {
                ZStack(alignment: .bottomLeading) {
                    Map(position: $heroCameraPosition, interactionModes: []) {
                        MapPolyline(coordinates: heroPoints.map { $0.coordinate })
                            .stroke(Color.prCoral, lineWidth: 4)
                    }
                    // Same hybrid style RideTelemetryMapView/GPXRouteMapView use
                    // for every other static/route map in this app.
                    .mapStyle(.hybrid(elevation: .realistic, showsTraffic: false))
                    .allowsHitTesting(false)
                    .frame(height: 190)

                    heroStatPill.padding(14)
                }
                .clipShape(RoundedRectangle(cornerRadius: 22))
                .padding(.horizontal, 16)

                heroTelemetryRow
            }
            .padding(.top, 24)
        } else {
            ZStack {
                Circle().fill(Color.prCoralSoft).frame(width: 88, height: 88)
                Image(systemName: "flag.checkered")
                    .font(.system(size: 36)).foregroundColor(.prCoral)
            }
            .padding(.top, 40)
        }
    }

    // Distance + Duration — the same values already shown in the
    // SummaryStatBox row below, surfaced again here as a floating glass
    // capsule over the route (same .ultraThinMaterial capsule treatment
    // NeedHelpView's own top-bar pill already uses).
    private var heroStatPill: some View {
        HStack(spacing: 12) {
            HStack(spacing: 5) {
                Image(systemName: "point.topleft.down.to.point.bottomright.curvepath").font(.system(size: 10, weight: .semibold))
                Text(MeasurementUnits.distanceMiles(distance)).font(.system(size: 13, weight: .bold, design: .monospaced))
            }
            Rectangle().fill(Color.white.opacity(0.4)).frame(width: 1, height: 12)
            HStack(spacing: 5) {
                Image(systemName: "clock.fill").font(.system(size: 10, weight: .semibold))
                Text(duration).font(.system(size: 13, weight: .bold, design: .monospaced))
            }
        }
        .foregroundColor(.white)
        .padding(.horizontal, 13).padding(.vertical, 9)
        .background(.ultraThinMaterial)
        .clipShape(Capsule())
    }

    // Compact Speed/Lean readout below the map — same icon-badge + value/
    // label layout language as SummaryStatBox, just horizontal and denser so
    // two fit side by side under the hero map instead of a third full box.
    // Values are maxSpeed/maxLeanAngle exactly as passed into this view.
    private var heroTelemetryRow: some View {
        HStack(spacing: 10) {
            HeroTelemetryChip(icon: "speedometer", value: MeasurementUnits.speedMph(maxSpeed), label: "Top Speed", color: .prTeal)
            // #1E88E5 — same unused-blue Lean Angle accent RideTelemetryMapView
            // already picked for this exact metric (no other lean-angle
            // convention exists elsewhere in the app); reused here rather than
            // choosing a second color for the same thing.
            HeroTelemetryChip(icon: "angle", value: String(format: "%.0f°", maxLeanAngle), label: "Max Lean", color: Color(red: 0.118, green: 0.533, blue: 0.898))
        }
        .padding(.horizontal, 16)
    }

    private func loadHeroRoute() {
        guard let path = gpxFilePath else { return }
        let points = GPXPointParser.parse(gpxFilePath: path)
        guard points.count > 1 else { return }
        heroPoints = points

        // Same bounds-fit formula GPXRouteMapView.parseGPX (RideHistoryView.swift)
        // and RideTelemetryMapView.fitCameraToRoute already use: center on the
        // route's min/max lat/lng, pad the span by 1.3x with a 0.01 floor.
        let lats = points.map { $0.latitude }
        let lngs = points.map { $0.longitude }
        guard let minLat = lats.min(), let maxLat = lats.max(),
              let minLng = lngs.min(), let maxLng = lngs.max() else { return }
        let center = CLLocationCoordinate2D(latitude: (minLat + maxLat) / 2, longitude: (minLng + maxLng) / 2)
        let span = MKCoordinateSpan(
            latitudeDelta: max((maxLat - minLat) * 1.3, 0.01),
            longitudeDelta: max((maxLng - minLng) * 1.3, 0.01)
        )
        heroCameraPosition = .region(MKCoordinateRegion(center: center, span: span))
    }
}

private struct HeroTelemetryChip: View {
    let icon: String; let value: String; let label: String; let color: Color
    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                Circle().fill(color.opacity(0.15)).frame(width: 34, height: 34)
                Image(systemName: icon).font(.system(size: 14)).foregroundColor(color)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(value).font(.system(size: 14, weight: .bold, design: .monospaced)).foregroundColor(.prInk)
                Text(label).font(.system(size: 10, weight: .medium)).foregroundColor(.prMuted)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12).padding(.vertical, 10)
        .background(Color.prCardBg)
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.prBorder, lineWidth: 1))
        .cornerRadius(14)
    }
}

struct SummaryStatBox: View {
    let value: String; let unit: String; let label: String
    var body: some View {
        VStack(spacing: 6) {
            HStack(alignment: .lastTextBaseline, spacing: 2) {
                Text(value)
                    .font(.system(size: 22, weight: .bold, design: .monospaced))
                    .foregroundColor(.prInk)
                if !unit.isEmpty {
                    Text(unit).font(.system(size: 11, weight: .medium))
                        .foregroundColor(.prMuted)
                }
            }
            Text(label).font(.system(size: 11, weight: .medium))
                .foregroundColor(.prMuted)
        }
        .frame(maxWidth: .infinity).padding(.vertical, 18)
        .background(Color.prCardBg).cornerRadius(14)
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.prBorder, lineWidth: 1))
    }
}

// MARK: - Ride Score Card (shown right after a ride ends)
struct RideScoreCard: View {
    let analytics: RideAnalyticsSummary
    var maxLeanAngle: Double = 0
    // Aug 24, 2026 — Ride Telemetry Map entry point (RideHistoryView.swift):
    // when this card is wrapped in a tappable Button opening the telemetry
    // map, showChevron adds the same chevron affordance used elsewhere in
    // this app for "this row opens something" (e.g. RidingDigestView/
    // RideTrendsView's NavigationLinks in RideHistoryView). Defaulted false
    // so RideSummaryView's own existing, non-tappable use of this card
    // (SoloRideView.swift) renders exactly as before.
    var showChevron: Bool = false

    var scoreColor: Color {
        switch analytics.rideScore {
        case 90...100: return Color(red: 0.180, green: 0.620, blue: 0.357)
        case 75..<90: return .prTeal
        case 55..<75: return .prCoral
        default: return Color(red: 0.827, green: 0.231, blue: 0.173)
        }
    }

    var body: some View {
        VStack(spacing: 14) {
            HStack(spacing: 14) {
                ZStack {
                    Circle().stroke(Color.prBorder, lineWidth: 6).frame(width: 60, height: 60)
                    Circle()
                        .trim(from: 0, to: CGFloat(analytics.rideScore) / 100)
                        .stroke(scoreColor, style: StrokeStyle(lineWidth: 6, lineCap: .round))
                        .frame(width: 60, height: 60)
                        .rotationEffect(.degrees(-90))
                    Text("\(analytics.rideScore)")
                        .font(.system(size: 16, weight: .bold, design: .monospaced))
                        .foregroundColor(.prInk)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("Ride Score: \(analytics.scoreGrade)")
                        .font(.system(size: 15, weight: .bold)).foregroundColor(.prInk)
                    Text("Estimated from GPS + motion sensors — not a precise instrument")
                        .font(.system(size: 10)).foregroundColor(.prMuted)
                }
                Spacer()
                if showChevron {
                    Image(systemName: "chevron.right").font(.system(size: 13, weight: .semibold)).foregroundColor(.prMuted)
                }
            }

            Divider().background(Color.prBorder)

            HStack(spacing: 0) {
                AnalyticsStatItem(icon: "arrow.triangle.swap", value: "\(analytics.smoothCornerCount)/\(analytics.cornerCount)", label: "Smooth Corners")
                AnalyticsStatItem(icon: "angle", value: String(format: "%.0f°", maxLeanAngle), label: "Max Lean")
                AnalyticsStatItem(icon: "hand.raised.fill", value: "\(analytics.hardBrakeCount)", label: "Hard Brakes")
                AnalyticsStatItem(icon: "bolt.fill", value: "\(analytics.hardAccelCount)", label: "Hard Accels")
            }
        }
        .padding(16)
        .background(Color.prCardBg)
        .cornerRadius(18)
        .overlay(RoundedRectangle(cornerRadius: 18).stroke(Color.prBorder, lineWidth: 1))
    }
}

struct AnalyticsStatItem: View {
    let icon: String; let value: String; let label: String
    var body: some View {
        VStack(spacing: 4) {
            Image(systemName: icon).font(.system(size: 12)).foregroundColor(.prCoral)
            Text(value).font(.system(size: 13, weight: .bold, design: .monospaced)).foregroundColor(.prInk)
            Text(label).font(.system(size: 9, weight: .medium)).foregroundColor(.prMuted)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
    }
}

// Legacy compatibility
struct InfoChip: View {
    let icon: String; let label: String
    var body: some View { EmptyView() }
}

#Preview {
    SoloRideView().environmentObject(CommunityMembershipStore())
}
