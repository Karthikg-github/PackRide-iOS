import SwiftUI
import MapKit
import CoreLocation

private struct DragRunRecord: Codable, Identifiable {
    let id: UUID
    let date: Date
    let distanceMeters: Double
    let elapsed: Double
    let trapSpeedMph: Double
    let zeroToSixty: Double?
    let eighthMile: Double?
    let quarterMile: Double?
}

struct DragModeView: View {
    let onOpenCircuit: () -> Void
    @ObservedObject private var location = SharedLocationManager.shared
    @State private var armed = false
    @State private var running = false
    @State private var startedAt: Date?
    @State private var elapsed = 0.0
    @State private var distanceMeters = 0.0
    @State private var lastLocation: CLLocation?
    @State private var route: [CLLocationCoordinate2D] = []
    @State private var zeroToSixty: Double?
    @State private var eighthMile: Double?
    @State private var quarterMile: Double?
    @State private var timer: Timer?
    @State private var runs: [DragRunRecord] = []
    @State private var showHistory = false
    @State private var camera: MapCameraPosition = .userLocation(fallback: .automatic)

    private var speedMph: Double { max(0, location.location?.speed ?? 0) * 2.236936 }
    private var gpsAccuracy: Double? { location.location?.horizontalAccuracy }
    private var readyToArm: Bool { (location.location?.horizontalAccuracy ?? 999) <= 20 && speedMph < 3 }

    var body: some View {
        ZStack {
            Map(position: $camera) {
                UserAnnotation()
                if route.count > 1 { MapPolyline(coordinates: route).stroke(.orange, lineWidth: 6) }
            }
            .mapStyle(.hybrid(elevation: .realistic, pointsOfInterest: .excludingAll, showsTraffic: false))
            .ignoresSafeArea()

            LinearGradient(colors: [.black.opacity(0.78), .clear, .black.opacity(0.68)], startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea().allowsHitTesting(false)

            VStack(spacing: 14) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("DRAG MODE").font(.system(size: 10, weight: .heavy)).tracking(2.6).foregroundColor(.prCoral)
                        Text(running ? "RUNNING" : armed ? "ARMED" : "Straight-line timing")
                            .font(.system(size: 25, weight: .bold, design: .rounded)).foregroundColor(.white)
                        Text(statusText).font(.system(size: 12, weight: .medium)).foregroundColor(.white.opacity(0.72))
                    }
                    Spacer()
                    Button("CIRCUIT", action: onOpenCircuit).dragTopButton()
                    Button(action: { showHistory = true }) {
                        Image(systemName: "clock.arrow.circlepath").frame(width: 38, height: 38)
                    }.dragTopButton()
                }.padding(.horizontal, 20).padding(.top, 22)

                Spacer()

                VStack(spacing: 16) {
                    HStack(spacing: 0) {
                        dragMetric(value: String(format: "%.1f", elapsed), label: "SECONDS")
                        dragMetric(value: MeasurementUnits.current == .metric ? String(format: "%.0f", distanceMeters) : String(format: "%.3f", distanceMeters / 1609.344), label: MeasurementUnits.current == .metric ? "METERS" : "MILES")
                        dragMetric(value: MeasurementUnits.speedMph(speedMph), label: "SPEED")
                    }
                    HStack(spacing: 10) {
                        splitPill("0–60", zeroToSixty)
                        splitPill("⅛ MILE", eighthMile)
                        splitPill("¼ MILE", quarterMile)
                    }
                    Text("PHONE GPS ESTIMATE · Closed course only. Results may differ from professional timing, especially launch and finish detection.")
                        .font(.system(size: 9, weight: .semibold)).foregroundColor(.white.opacity(0.62))
                    Button(action: primaryAction) {
                        Label(running ? "End Run" : armed ? "Disarm" : "Arm Run", systemImage: running ? "stop.fill" : "bolt.fill")
                            .font(.system(size: 17, weight: .heavy)).foregroundColor(.white)
                            .frame(maxWidth: .infinity).padding(.vertical, 17)
                            .background(running ? Color.red : readyToArm || armed ? Color.prCoral : Color.gray)
                            .clipShape(RoundedRectangle(cornerRadius: 18))
                    }.disabled(!running && !armed && !readyToArm)
                }
                .padding(18).background(Color.black.opacity(0.68)).clipShape(RoundedRectangle(cornerRadius: 22))
                .overlay(RoundedRectangle(cornerRadius: 22).stroke(.white.opacity(0.14)))
                .padding(.horizontal, 16).padding(.bottom, 24)
            }
        }
        .toolbar(.hidden, for: .navigationBar)
        .onAppear { loadRuns(); location.startUpdating(reason: "dragMode") }
        .onDisappear { timer?.invalidate(); location.stopUpdating(reason: "dragMode") }
        .onChange(of: location.location) { _, fix in process(fix) }
        .sheet(isPresented: $showHistory) { dragHistory }
    }

    private var statusText: String {
        if running { return "Timing from detected movement" }
        if armed { return "Hold still, then launch when ready" }
        if !readyToArm { return "Stop and wait for an accurate GPS lock" }
        return "Ready for a closed-course run"
    }

    private func primaryAction() {
        if running { finishRun() }
        else if armed { armed = false }
        else {
            resetRun(); armed = true
        }
    }

    private func process(_ fix: CLLocation?) {
        guard let fix, fix.horizontalAccuracy >= 0, fix.horizontalAccuracy <= 25 else { return }
        if armed && !running && fix.speed >= 1.5 {
            armed = false; running = true; startedAt = fix.timestamp; lastLocation = fix; route = [fix.coordinate]
            timer?.invalidate()
            timer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { _ in
                if let startedAt { elapsed = Date().timeIntervalSince(startedAt) }
            }
            return
        }
        guard running else { return }
        if let previous = lastLocation, fix.timestamp > previous.timestamp {
            let step = fix.distance(from: previous)
            if step < 100 { distanceMeters += step }
        }
        lastLocation = fix; route.append(fix.coordinate)
        elapsed = fix.timestamp.timeIntervalSince(startedAt ?? fix.timestamp)
        if zeroToSixty == nil && speedMph >= 60 { zeroToSixty = elapsed }
        if eighthMile == nil && distanceMeters >= 201.168 { eighthMile = elapsed }
        if distanceMeters >= 402.336 { quarterMile = quarterMile ?? elapsed; finishRun() }
    }

    private func finishRun() {
        guard running else { return }
        timer?.invalidate(); running = false; armed = false
        let record = DragRunRecord(id: UUID(), date: Date(), distanceMeters: distanceMeters, elapsed: elapsed,
                                   trapSpeedMph: speedMph, zeroToSixty: zeroToSixty, eighthMile: eighthMile, quarterMile: quarterMile)
        runs.insert(record, at: 0)
        if let data = try? JSONEncoder().encode(runs) { UserDefaults.standard.set(data, forKey: "dragRunHistory") }
    }

    private func resetRun() {
        timer?.invalidate(); startedAt = nil; elapsed = 0; distanceMeters = 0; lastLocation = nil; route = []
        zeroToSixty = nil; eighthMile = nil; quarterMile = nil
    }

    private func dragMetric(value: String, label: String) -> some View {
        VStack(spacing: 3) { Text(value).font(.system(size: 19, weight: .heavy, design: .monospaced)); Text(label).font(.system(size: 8, weight: .heavy)).tracking(1.2).opacity(0.55) }
            .foregroundColor(.white).frame(maxWidth: .infinity)
    }
    private func splitPill(_ label: String, _ value: Double?) -> some View {
        VStack(spacing: 3) { Text(value.map { String(format: "%.2fs", $0) } ?? "—").font(.system(size: 13, weight: .bold, design: .monospaced)); Text(label).font(.system(size: 8, weight: .heavy)).opacity(0.55) }
            .foregroundColor(.white).frame(maxWidth: .infinity).padding(.vertical, 10).background(.white.opacity(0.08)).clipShape(RoundedRectangle(cornerRadius: 12))
    }
    private func loadRuns() { if let data = UserDefaults.standard.data(forKey: "dragRunHistory"), let decoded = try? JSONDecoder().decode([DragRunRecord].self, from: data) { runs = decoded } }

    private var dragHistory: some View {
        NavigationStack {
            List(runs) { run in
                VStack(alignment: .leading, spacing: 4) {
                    Text(run.quarterMile.map { "¼ mile · \(String(format: "%.2fs", $0))" } ?? "Drag run · \(String(format: "%.2fs", run.elapsed))").font(.headline)
                    Text(run.date.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundColor(.secondary)
                    Text("\(String(format: "%.0f", run.distanceMeters)) m · \(MeasurementUnits.speedMph(run.trapSpeedMph)) trap").font(.caption)
                }
            }.navigationTitle("Drag Runs").toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { showHistory = false } } }
        }
    }
}

private extension View {
    func dragTopButton() -> some View {
        self.font(.system(size: 10, weight: .heavy)).foregroundColor(.white).padding(.horizontal, 11).frame(height: 38)
            .background(Color.black.opacity(0.44)).clipShape(Capsule())
    }
}
