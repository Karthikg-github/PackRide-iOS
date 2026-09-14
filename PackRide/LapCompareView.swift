import SwiftUI
import Charts
import CoreLocation
import MapKit

// MARK: - Lap Compare (Karthik's spec — "I want to compare my lap 5 to lap
// 9... if I'm riding with my friend and he is using the same app, they should
// be able to share the session and we should be able to compare our
// telemetry... full flexibility to compare any of your own sessions/laps
// against any other, same session or different, same day or any other day.")
//
// Two independent slots (Lap A / Lap B), each filled from either this
// device's own Track Mode history (LapHistoryManager) or a session a friend
// shared (LapSharingManager) — same session or different, own or a friend's,
// same day or any other day, no restriction. Once both slots have a lap
// chosen, LapReconstructor pulls each lap's own point trace out of its
// session's GPX (Part A) and LapComparisonBuilder distance-aligns the two
// onto one shared grid (Part B) for the chart + delta strip below.

// MARK: - A single chosen lap, independent of where it came from
private struct ChosenLap: Identifiable, Equatable {
    let id = UUID()
    let ownerLabel: String       // "You" or the friend's rider name
    let trackName: String
    let date: Date
    let lapIndex: Int            // 0-based, into lapDurations
    let lapDurations: [Double]   // the FULL session's lap splits, needed to reconstruct this one lap
    let lapStartTimestamps: [Int64]
    let gpxFileURL: URL          // resolved, ready to parse — local file either way (own recording, or already-cached shared copy)

    static func == (lhs: ChosenLap, rhs: ChosenLap) -> Bool { lhs.id == rhs.id }

    var lapNumber: Int { lapIndex + 1 }
    var lapTime: Double { lapIndex < lapDurations.count ? lapDurations[lapIndex] : 0 }
}

struct LapCompareView: View {
    // Optional presets — the two entry points this screen has:
    //  - LapSessionSummaryView's "Compare Laps" hands in `presetSessionGPXPath`
    //    + `presetLapDurations` etc. so Slot A opens already filled with the
    //    best lap of the session just finished.
    //  - LapTrendsView's per-track "Compare Laps" link (when it fits — see
    //    that file) hands in just `initialTrackFilter` to pre-filter both
    //    slot pickers to that track, leaving both slots empty.
    var presetSlotA: PresetLap? = nil
    var initialTrackFilter: String? = nil

    struct PresetLap {
        let trackName: String
        let date: Date
        let lapIndex: Int
        let lapDurations: [Double]
        var lapStartTimestamps: [Int64] = []
        let gpxFilePath: String   // GPXStorage-relative filename
    }

    @Environment(\.dismiss) var dismiss

    @StateObject private var historyManager = LapHistoryManager()
    @StateObject private var sharingManager = LapSharingManager()

    @State private var slotA: ChosenLap? = nil
    @State private var slotB: ChosenLap? = nil
    @State private var traceA: ReconstructedLap? = nil
    @State private var traceB: ReconstructedLap? = nil
    @State private var comparison: LapCompareResult? = nil
    @State private var loadErrorA: String? = nil
    @State private var loadErrorB: String? = nil
    @State private var isLoadingA = false
    @State private var isLoadingB = false

    @State private var showPickerForSlot: Slot? = nil
    @State private var selectedMetric: LapCompareMetric = .speed
    @State private var selectedSampleIndex: Int? = nil
    @State private var isPlaying = false
    @State private var playbackTask: Task<Void, Never>? = nil

    private enum Slot { case a, b }

    // Two visually distinct colors already used together for exactly this
    // kind of "two related lines" chart elsewhere in the app — LapTrendsView's
    // Best Lap Trend (prCoral) and Track Score (prTeal) — reused here as-is
    // rather than inventing a new pairing.
    private let colorA = Color.prCoral
    private let colorB = Color(red: 0.180, green: 0.620, blue: 0.357)
    private let aheadColor = Color(red: 0.180, green: 0.620, blue: 0.357)   // same green LapEngine.deltaColor uses for "ahead"
    private let behindColor = Color(red: 0.827, green: 0.231, blue: 0.173)  // same red LapEngine.deltaColor uses for "behind"

    var body: some View {
            ZStack {
                Color.prBg.ignoresSafeArea()
                ScrollView(showsIndicators: false) {
                    VStack(spacing: 0) {
                        PRWebPageHeader(
                            eyebrow: "LAP ANALYTICS",
                            title: "Compare Laps",
                            subtitle: "See where one run pulls away from another"
                        )

                        slotRow
                            .padding(.top, 2)

                        if let comparison {
                            PRWebSectionLabel(title: "Result", detail: "Distance aligned")
                            headerStats(comparison)

                            PRWebSectionLabel(title: "Track Position", detail: "Drag the telemetry graph")
                            trackPositionCard(comparison)

                            PRWebSectionLabel(title: "Telemetry", detail: "Choose a metric")
                            metricPicker

                            chartCard(comparison)
                            deltaStripCard(comparison)
                        } else {
                            PRWebSectionLabel(title: "Build a comparison", detail: "Two laps required")
                            emptyState
                        }
                    }
                    .padding(.bottom, 28)
                }
            }
            .toolbar(.hidden, for: .navigationBar)
            .overlay(alignment: .topTrailing) {
                Button("Done") { dismiss() }
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(.prInk)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                    .background(.ultraThinMaterial)
                    .clipShape(Capsule())
                    .overlay(Capsule().stroke(Color.prBorder, lineWidth: 1))
                    .padding(.trailing, 18)
                    .padding(.top, 18)
            }
            .onAppear {
                historyManager.loadSessions()
                sharingManager.listenForSharedSessions()
                applyPreset()
            }
            .onDisappear { sharingManager.stopListening() }
            .onDisappear { stopPlayback() }
            .sheet(item: Binding(
                get: { showPickerForSlot.map { PickerToken(slot: $0) } },
                set: { showPickerForSlot = $0?.slot }
            )) { token in
                LapPickerSheet(
                    historyManager: historyManager,
                    sharingManager: sharingManager,
                    defaultTrackFilter: (token.slot == .a ? slotB?.trackName : slotA?.trackName) ?? initialTrackFilter
                ) { chosen in
                    assign(chosen, to: token.slot)
                }
            }
    }

    private struct PickerToken: Identifiable { let slot: Slot; var id: String { slot == .a ? "a" : "b" } }

    // MARK: - Preset (from LapSessionSummaryView / LapTrendsView)
    private func applyPreset() {
        guard slotA == nil, let preset = presetSlotA else { return }
        let url = GPXStorage.resolve(preset.gpxFilePath)
        let chosen = ChosenLap(
            ownerLabel: "You", trackName: preset.trackName, date: preset.date,
            lapIndex: preset.lapIndex, lapDurations: preset.lapDurations,
            lapStartTimestamps: preset.lapStartTimestamps, gpxFileURL: url
        )
        assign(chosen, to: .a)
    }

    private func assign(_ chosen: ChosenLap, to slot: Slot) {
        switch slot {
        case .a:
            slotA = chosen
            traceA = nil
            loadErrorA = nil
            isLoadingA = true
        case .b:
            slotB = chosen
            traceB = nil
            loadErrorB = nil
            isLoadingB = true
        }
        loadTrace(chosen) { trace in
            switch slot {
            case .a:
                isLoadingA = false
                if let trace { traceA = trace } else { loadErrorA = "Couldn't read this lap's recorded route." }
            case .b:
                isLoadingB = false
                if let trace { traceB = trace } else { loadErrorB = "Couldn't read this lap's recorded route." }
            }
            refreshComparison()
        }
    }

    // GPX parsing + lap reconstruction is done off the main thread since a
    // long session's file can be a few thousand points — keeps picking a lap
    // from feeling like it hangs the sheet-dismiss animation.
    private func loadTrace(_ chosen: ChosenLap, completion: @escaping (ReconstructedLap?) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let points = GPXPointParser.parse(fileURL: chosen.gpxFileURL)
            let laps = LapReconstructor.reconstructLaps(points: points, lapDurations: chosen.lapDurations,
                                                        lapStartTimestamps: chosen.lapStartTimestamps)
            let trace = laps.first { $0.lapIndex == chosen.lapIndex }
            DispatchQueue.main.async { completion(trace) }
        }
    }

    private func refreshComparison() {
        guard let traceA, let traceB else { comparison = nil; return }
        comparison = LapComparisonBuilder.build(lapA: traceA, lapB: traceB)
        selectedSampleIndex = 0
    }

    // MARK: - Slot Row
    private var slotRow: some View {
        HStack(spacing: 12) {
            slotCard(label: "Lap A", accent: colorA, chosen: slotA, isLoading: isLoadingA, error: loadErrorA) {
                showPickerForSlot = .a
            }
            slotCard(label: "Lap B", accent: colorB, chosen: slotB, isLoading: isLoadingB, error: loadErrorB) {
                showPickerForSlot = .b
            }
        }
        .padding(.horizontal, 16)
    }

    private func slotCard(label: String, accent: Color, chosen: ChosenLap?, isLoading: Bool, error: String?, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Circle().fill(accent).frame(width: 8, height: 8)
                    Text(label).font(.system(size: 11, weight: .bold)).foregroundColor(.prMuted).tracking(1)
                    Spacer()
                    Image(systemName: "chevron.down").font(.system(size: 10, weight: .bold)).foregroundColor(.prMuted)
                }
                if let chosen {
                    Text("Lap \(chosen.lapNumber)").font(.system(size: 17, weight: .bold, design: .monospaced)).foregroundColor(.prInk)
                    Text(LapEngine.formatLapTime(chosen.lapTime)).font(.system(size: 13, weight: .semibold, design: .monospaced)).foregroundColor(accent)
                    Text("\(chosen.ownerLabel) · \(chosen.trackName)").font(.system(size: 10)).foregroundColor(.prMuted).lineLimit(1)
                } else if isLoading {
                    ProgressView().padding(.vertical, 6)
                } else {
                    Text("Choose a Lap").font(.system(size: 14, weight: .semibold)).foregroundColor(.prMuted)
                        .padding(.top, 4).padding(.bottom, 8)
                }
                if let error {
                    Text(error).font(.system(size: 10)).foregroundColor(behindColor)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .background(Color.black.opacity(0.04))
            .cornerRadius(18)
            .overlay(RoundedRectangle(cornerRadius: 18).stroke(Color.prBorder, lineWidth: 1))
        }
    }

    // MARK: - Empty State
    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "chart.xyaxis.line").font(.system(size: 30)).foregroundColor(.prMuted)
            Text("Pick a lap for both slots").font(.system(size: 15, weight: .bold)).foregroundColor(.prInk)
            Text("Any lap from any session — your own or a friend's, the same session or a completely different day.")
                .font(.system(size: 12)).foregroundColor(.prMuted)
                .multilineTextAlignment(.center).padding(.horizontal, 40)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 50)
    }

    // MARK: - Header Stats
    private func headerStats(_ comparison: LapCompareResult) -> some View {
        HStack(spacing: 0) {
            headerStat(value: LapEngine.formatLapTime(comparison.lapADuration), label: "Lap A Time", color: colorA)
            headerStat(value: LapEngine.formatLapTime(comparison.lapBDuration), label: "Lap B Time", color: colorB)
            headerStat(
                value: LapEngine.formatDelta(comparison.finishDelta), label: "At Finish",
                color: comparison.finishDelta <= 0 ? aheadColor : behindColor
            )
        }
        .padding(.horizontal, 16)
    }

    private func headerStat(value: String, label: String, color: Color) -> some View {
        VStack(spacing: 4) {
            Text(value).font(.system(size: 16, weight: .bold, design: .monospaced)).foregroundColor(color)
            Text(label).font(.system(size: 10, weight: .medium)).foregroundColor(.prMuted)
        }
        .frame(maxWidth: .infinity).padding(.vertical, 12)
        .background(Color.prCardBg).cornerRadius(12)
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.prBorder, lineWidth: 1))
    }

    // MARK: - Metric Toggle
    private var metricPicker: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(LapCompareMetric.allCases) { metric in
                    Button(action: { selectedMetric = metric }) {
                        Text(metric.rawValue)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(selectedMetric == metric ? .white : .prMuted)
                            .padding(.horizontal, 14).padding(.vertical, 8)
                            .background(selectedMetric == metric ? Color.prCoral : Color.prCardBg)
                            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.prBorder, lineWidth: selectedMetric == metric ? 0 : 1))
                            .cornerRadius(10)
                    }
                }
            }
            .padding(.horizontal, 16)
        }
    }

    // MARK: - Dual-Line Chart
    private func chartCard(_ comparison: LapCompareResult) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(selectedMetric.rawValue) vs. Distance").font(.system(size: 14, weight: .bold)).foregroundColor(.prInk)
                    Text("compared over \(String(format: "%.0f", comparison.comparedDistance)) m — the shorter lap's own distance")
                        .font(.system(size: 11)).foregroundColor(.prMuted)
                }
                Spacer()
            }
            Chart {
                ForEach(comparison.samples) { sample in
                    LineMark(
                        x: .value("Distance", sample.distanceMeters),
                        y: .value("Lap A", sample.metricsA[selectedMetric] ?? 0),
                        series: .value("Lap", "A")
                    )
                    .foregroundStyle(colorA)
                    .interpolationMethod(.catmullRom)
                }
                ForEach(comparison.samples) { sample in
                    LineMark(
                        x: .value("Distance", sample.distanceMeters),
                        y: .value("Lap B", sample.metricsB[selectedMetric] ?? 0),
                        series: .value("Lap", "B")
                    )
                    .foregroundStyle(colorB)
                    .interpolationMethod(.catmullRom)
                }
                if let selected = selectedSample(in: comparison) {
                    RuleMark(x: .value("Selected distance", selected.distanceMeters))
                        .foregroundStyle(Color.prMuted.opacity(0.7))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                    PointMark(
                        x: .value("Distance", selected.distanceMeters),
                        y: .value("Lap A", selected.metricsA[selectedMetric] ?? 0)
                    )
                    .symbolSize(75).foregroundStyle(colorA)
                    .annotation(position: .top, spacing: 8) {
                        telemetryBadge(label: "A", value: selected.metricsA[selectedMetric] ?? 0, color: colorA)
                    }
                    PointMark(
                        x: .value("Distance", selected.distanceMeters),
                        y: .value("Lap B", selected.metricsB[selectedMetric] ?? 0)
                    )
                    .symbolSize(75).foregroundStyle(colorB)
                    .annotation(position: .bottom, spacing: 8) {
                        telemetryBadge(label: "B", value: selected.metricsB[selectedMetric] ?? 0, color: colorB)
                    }
                }
            }
            .frame(height: 210)
            .chartXAxisLabel("meters into lap")
            .chartYAxisLabel(selectedMetric.unit)
            .chartOverlay { proxy in
                GeometryReader { geometry in
                    Rectangle().fill(.clear).contentShape(Rectangle())
                        .gesture(
                            DragGesture(minimumDistance: 0)
                                .onChanged { value in
                                    stopPlayback()
                                    guard let plotFrame = proxy.plotFrame else { return }
                                    let frame = geometry[plotFrame]
                                    let x = value.location.x - frame.origin.x
                                    guard x >= 0, x <= frame.width,
                                          let distance: Double = proxy.value(atX: x) else { return }
                                    selectedSampleIndex = comparison.samples.indices.min {
                                        abs(comparison.samples[$0].distanceMeters - distance) <
                                        abs(comparison.samples[$1].distanceMeters - distance)
                                    }
                                }
                        )
                }
            }

            if let selected = selectedSample(in: comparison) {
                HStack(spacing: 10) {
                    playbackValueCard(label: "Lap A", value: selected.metricsA[selectedMetric] ?? 0, color: colorA)
                    playbackValueCard(label: "Lap B", value: selected.metricsB[selectedMetric] ?? 0, color: colorB)
                }
            }

            HStack(spacing: 16) {
                legendDot(color: colorA, label: "Lap A")
                legendDot(color: colorB, label: "Lap B")
            }
        }
        .padding(16)
        .background(Color.prCardBg)
        .cornerRadius(16)
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.prBorder, lineWidth: 1))
        .padding(.horizontal, 16)
    }

    private func selectedSample(in comparison: LapCompareResult) -> LapCompareSample? {
        guard let selectedSampleIndex, comparison.samples.indices.contains(selectedSampleIndex) else { return nil }
        return comparison.samples[selectedSampleIndex]
    }

    private func telemetryBadge(label: String, value: Double, color: Color) -> some View {
        Text("\(label)  \(String(format: "%.2f", value)) \(selectedMetric.unit)")
            .font(.system(size: 10, weight: .bold, design: .monospaced))
            .foregroundColor(.white)
            .padding(.horizontal, 8).padding(.vertical, 5)
            .background(color).clipShape(Capsule())
    }

    private func playbackValueCard(label: String, value: Double, color: Color) -> some View {
        HStack(spacing: 7) {
            Circle().fill(color).frame(width: 9, height: 9)
            VStack(alignment: .leading, spacing: 1) {
                Text(label).font(.system(size: 9, weight: .bold)).foregroundColor(.prMuted)
                Text("\(String(format: "%.2f", value)) \(selectedMetric.unit)")
                    .font(.system(size: 13, weight: .bold, design: .monospaced)).foregroundColor(color)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .background(Color.black.opacity(0.035)).clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private func trackPositionCard(_ comparison: LapCompareResult) -> some View {
        let selected = selectedSample(in: comparison) ?? comparison.samples.first
        return VStack(alignment: .leading, spacing: 10) {
            Text("Lap position at \(String(format: "%.0f", selected?.distanceMeters ?? 0)) m")
                .font(.system(size: 13, weight: .bold)).foregroundColor(.prInk)
            if let traceA, let traceB {
                LapPositionSatelliteMap(
                    pointsA: traceA.points,
                    pointsB: traceB.points,
                    distanceA: selected?.distanceMeters ?? 0,
                    distanceB: selected?.distanceMeters ?? 0,
                    colorA: colorA,
                    colorB: colorB
                )
                .frame(height: 220)
            }
            HStack(spacing: 12) {
                Button(action: { togglePlayback(comparison) }) {
                    Label(isPlaying ? "Pause" : "Play", systemImage: isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 18).padding(.vertical, 10)
                        .background(isPlaying ? colorB : colorA).clipShape(Capsule())
                }
                Spacer()
                if let selected {
                    Text("\(String(format: "%.0f", selected.distanceMeters)) / \(String(format: "%.0f", comparison.comparedDistance)) m")
                        .font(.system(size: 12, weight: .bold, design: .monospaced)).foregroundColor(.prMuted)
                }
            }
            HStack(spacing: 16) {
                legendDot(color: colorA, label: "Lap A position")
                legendDot(color: colorB, label: "Lap B position")
            }
        }
        .padding(16)
        .background(Color.prCardBg)
        .cornerRadius(16)
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.prBorder, lineWidth: 1))
        .padding(.horizontal, 16)
    }

    private func togglePlayback(_ comparison: LapCompareResult) {
        if isPlaying { stopPlayback(); return }
        if selectedSampleIndex == nil || selectedSampleIndex == comparison.samples.count - 1 {
            selectedSampleIndex = 0
        }
        isPlaying = true
        playbackTask?.cancel()
        playbackTask = Task { @MainActor in
            while !Task.isCancelled && isPlaying {
                try? await Task.sleep(nanoseconds: 120_000_000)
                guard !Task.isCancelled, isPlaying else { break }
                let next = (selectedSampleIndex ?? 0) + 1
                if next >= comparison.samples.count {
                    selectedSampleIndex = comparison.samples.indices.last
                    stopPlayback()
                } else {
                    selectedSampleIndex = next
                }
            }
        }
    }

    private func stopPlayback() {
        isPlaying = false
        playbackTask?.cancel()
        playbackTask = nil
    }

    private func legendDot(color: Color, label: String) -> some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(label).font(.system(size: 11, weight: .medium)).foregroundColor(.prMuted)
        }
    }

    // MARK: - Delta Strip
    private func deltaStripCard(_ comparison: LapCompareResult) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Delta vs. Distance").font(.system(size: 14, weight: .bold)).foregroundColor(.prInk)
                Text("green = Lap B ahead of Lap A's pace here, red = behind")
                    .font(.system(size: 11)).foregroundColor(.prMuted)
            }
            Chart(comparison.samples) { sample in
                BarMark(
                    x: .value("Distance", sample.distanceMeters),
                    y: .value("Delta", sample.deltaSeconds)
                )
                .foregroundStyle(sample.deltaSeconds <= 0 ? aheadColor : behindColor)
            }
            .frame(height: 90)
            .chartXAxisLabel("meters into lap")
        }
        .padding(16)
        .background(Color.prCardBg)
        .cornerRadius(16)
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.prBorder, lineWidth: 1))
        .padding(.horizontal, 16)
    }
}

private struct LapPositionSatelliteMap: View {
    let pointsA: [LapTracePoint]
    let pointsB: [LapTracePoint]
    let distanceA: Double
    let distanceB: Double
    let colorA: Color
    let colorB: Color

    private var coordinatesA: [CLLocationCoordinate2D] { pointsA.map(\.sample.coordinate) }
    private var coordinatesB: [CLLocationCoordinate2D] { pointsB.map(\.sample.coordinate) }

    private var selectedA: CLLocationCoordinate2D? {
        pointsA.min { abs($0.distanceIntoLap - distanceA) < abs($1.distanceIntoLap - distanceA) }?.sample.coordinate
    }
    private var selectedB: CLLocationCoordinate2D? {
        pointsB.min { abs($0.distanceIntoLap - distanceB) < abs($1.distanceIntoLap - distanceB) }?.sample.coordinate
    }
    private var region: MKCoordinateRegion {
        let all = coordinatesA + coordinatesB
        guard let first = all.first else {
            return MKCoordinateRegion(center: CLLocationCoordinate2D(latitude: 0, longitude: 0), span: MKCoordinateSpan(latitudeDelta: 0.01, longitudeDelta: 0.01))
        }
        let minLat = all.map(\.latitude).min() ?? first.latitude
        let maxLat = all.map(\.latitude).max() ?? first.latitude
        let minLng = all.map(\.longitude).min() ?? first.longitude
        let maxLng = all.map(\.longitude).max() ?? first.longitude
        return MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: (minLat + maxLat) / 2, longitude: (minLng + maxLng) / 2),
            span: MKCoordinateSpan(latitudeDelta: max((maxLat - minLat) * 1.35, 0.0008), longitudeDelta: max((maxLng - minLng) * 1.35, 0.0008))
        )
    }

    var body: some View {
        Map(initialPosition: .region(region), interactionModes: []) {
            if coordinatesA.count > 1 { MapPolyline(coordinates: coordinatesA).stroke(colorA.opacity(0.9), lineWidth: 4) }
            if coordinatesB.count > 1 { MapPolyline(coordinates: coordinatesB).stroke(colorB.opacity(0.9), lineWidth: 4) }
            if let selectedA {
                Annotation("Lap A", coordinate: selectedA) { positionDot(colorA) }
            }
            if let selectedB {
                Annotation("Lap B", coordinate: selectedB) { positionDot(colorB) }
            }
        }
        .mapStyle(.imagery(elevation: .flat))
        .mapControlVisibility(.hidden)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.prBorder, lineWidth: 1))
    }

    private func positionDot(_ color: Color) -> some View {
        Circle().fill(color).frame(width: 16, height: 16)
            .overlay(Circle().stroke(.white, lineWidth: 3))
            .shadow(color: .black.opacity(0.35), radius: 2)
    }
}

// MARK: - Lap Picker Sheet
// "My Sessions" / "Shared with Me" tabs, a track-name filter (defaulting to
// whatever the OTHER slot is already set to, overridable back to "All
// Tracks"), tap a session to see its individual lap splits, tap a lap to
// finalize the pick. Full flexibility — any lap, any session, own or a
// friend's, matching Karthik's original spec exactly.
private struct LapPickerSheet: View {
    @ObservedObject var historyManager: LapHistoryManager
    @ObservedObject var sharingManager: LapSharingManager
    let defaultTrackFilter: String?
    let onPick: (ChosenLap) -> Void

    @Environment(\.dismiss) var dismiss
    @State private var tab: Tab = .mine
    @State private var trackFilter: String = "All Tracks"
    @State private var expandedMineSession: LapRecord? = nil
    @State private var expandedSharedSession: SharedLapSession? = nil
    @State private var downloadError: String? = nil
    @State private var isDownloading = false

    private enum Tab { case mine, shared }
    private let allTracksLabel = "All Tracks"

    private var mineTrackNames: [String] {
        trackNames(from: historyManager.sessions.map { $0.trackName.isEmpty ? "Track Session" : $0.trackName })
    }
    private var sharedTrackNames: [String] {
        trackNames(from: sharingManager.sharedWithMe.map { $0.trackName.isEmpty ? "Track Session" : $0.trackName })
    }
    private func trackNames(from raw: [String]) -> [String] {
        var seen = Set<String>()
        var ordered: [String] = [allTracksLabel]
        for name in raw where !seen.contains(name) {
            seen.insert(name)
            ordered.append(name)
        }
        return ordered
    }

    private var filteredMineSessions: [LapRecord] {
        historyManager.sessions
            .filter { $0.laps.count >= 1 && ($0.gpxFilePath != nil || $0.gpxURL != nil) }
            .filter { trackFilter == allTracksLabel || ($0.trackName.isEmpty ? "Track Session" : $0.trackName) == trackFilter }
    }
    private var filteredSharedSessions: [SharedLapSession] {
        sharingManager.sharedWithMe
            .filter { !$0.laps.isEmpty }
            .filter { trackFilter == allTracksLabel || ($0.trackName.isEmpty ? "Track Session" : $0.trackName) == trackFilter }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                tabBar
                trackPicker
                ScrollView {
                    LazyVStack(spacing: 10) {
                        if tab == .mine {
                            if filteredMineSessions.isEmpty {
                                emptyRow("No sessions with a recorded route at this track yet.")
                            } else {
                                ForEach(filteredMineSessions) { session in
                                    mineSessionRow(session)
                                }
                            }
                        } else {
                            if filteredSharedSessions.isEmpty {
                                emptyRow("No sessions shared with you at this track yet.")
                            } else {
                                ForEach(filteredSharedSessions) { session in
                                    sharedSessionRow(session)
                                }
                            }
                        }
                        if let downloadError {
                            Text(downloadError).font(.system(size: 11)).foregroundColor(Color(red: 0.827, green: 0.231, blue: 0.173))
                                .padding(.horizontal, 16)
                        }
                    }
                    .padding(16)
                }
            }
            .background(Color.prBg)
            .navigationTitle("Choose a Lap")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { Button("Cancel") { dismiss() } }
            }
            .onAppear {
                trackFilter = defaultTrackFilter ?? allTracksLabel
                if !mineTrackNames.contains(trackFilter) && !sharedTrackNames.contains(trackFilter) {
                    trackFilter = allTracksLabel
                }
            }
        }
    }

    private var tabBar: some View {
        HStack(spacing: 8) {
            tabButton(title: "My Sessions", isSelected: tab == .mine) { tab = .mine }
            tabButton(title: "Shared with Me", isSelected: tab == .shared) { tab = .shared }
        }
        .padding(.horizontal, 16).padding(.top, 12)
    }

    private func tabButton(title: String, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 13, weight: .bold))
                .foregroundColor(isSelected ? .white : .prMuted)
                .frame(maxWidth: .infinity).padding(.vertical, 10)
                .background(isSelected ? Color.prCoral : Color.prCardBg)
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.prBorder, lineWidth: isSelected ? 0 : 1))
                .cornerRadius(10)
        }
    }

    private var trackPicker: some View {
        let names = tab == .mine ? mineTrackNames : sharedTrackNames
        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(names, id: \.self) { name in
                    Button(action: { trackFilter = name }) {
                        Text(name)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(trackFilter == name ? .white : .prMuted)
                            .padding(.horizontal, 12).padding(.vertical, 7)
                            .background(trackFilter == name ? Color.prTeal : Color.prCardBg)
                            .overlay(RoundedRectangle(cornerRadius: 9).stroke(Color.prBorder, lineWidth: trackFilter == name ? 0 : 1))
                            .cornerRadius(9)
                    }
                }
            }
            .padding(.horizontal, 16).padding(.top, 10)
        }
    }

    private func emptyRow(_ text: String) -> some View {
        Text(text).font(.system(size: 12)).foregroundColor(.prMuted)
            .multilineTextAlignment(.center).padding(.vertical, 30)
            .frame(maxWidth: .infinity)
    }

    // MARK: - My Sessions
    private func mineSessionRow(_ session: LapRecord) -> some View {
        let isExpanded = expandedMineSession?.id == session.id
        return VStack(spacing: 0) {
            Button(action: {
                withAnimation { expandedMineSession = isExpanded ? nil : session }
            }) {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(session.trackName.isEmpty ? "Track Session" : session.trackName)
                            .font(.system(size: 14, weight: .semibold)).foregroundColor(.prInk)
                        Text(session.formattedDate).font(.system(size: 11)).foregroundColor(.prMuted)
                    }
                    Spacer()
                    Text("\(session.lapCount) laps").font(.system(size: 12, weight: .semibold)).foregroundColor(.prMuted)
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 11, weight: .bold)).foregroundColor(.prMuted)
                }
                .padding(14)
            }
            if isExpanded {
                lapList(count: session.laps.count, durations: session.laps, bestTime: session.bestLapTime) { index in
                    isDownloading = true
                    historyManager.resolveGPX(session) { url in
                        isDownloading = false
                        guard let url else { downloadError = "Couldn't download this session's route."; return }
                        onPick(ChosenLap(
                            ownerLabel: "You", trackName: session.trackName.isEmpty ? "Track Session" : session.trackName,
                            date: session.date, lapIndex: index, lapDurations: session.laps,
                            lapStartTimestamps: session.lapStartTimestamps, gpxFileURL: url
                        ))
                        dismiss()
                    }
                }
            }
        }
        .background(Color.prCardBg)
        .cornerRadius(14)
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.prBorder, lineWidth: 1))
    }

    // MARK: - Shared with Me
    private func sharedSessionRow(_ session: SharedLapSession) -> some View {
        let isExpanded = expandedSharedSession?.id == session.id
        return VStack(spacing: 0) {
            Button(action: {
                withAnimation { expandedSharedSession = isExpanded ? nil : session }
            }) {
                HStack(spacing: 12) {
                    ZStack {
                        Circle().fill(Color.prTeal).frame(width: 32, height: 32)
                        Text(session.ownerName.rideInitials).font(.system(size: 11, weight: .bold)).foregroundColor(.white)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(session.trackName.isEmpty ? "Track Session" : session.trackName)
                            .font(.system(size: 14, weight: .semibold)).foregroundColor(.prInk)
                        Text("\(session.ownerName) · \(session.formattedDate)").font(.system(size: 11)).foregroundColor(.prMuted)
                    }
                    Spacer()
                    Text("\(session.lapCount) laps").font(.system(size: 12, weight: .semibold)).foregroundColor(.prMuted)
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 11, weight: .bold)).foregroundColor(.prMuted)
                }
                .padding(14)
            }
            if isExpanded {
                if isDownloading {
                    ProgressView().padding(.bottom, 14)
                } else {
                    lapList(count: session.laps.count, durations: session.laps, bestTime: session.bestLapTime) { index in
                        downloadError = nil
                        isDownloading = true
                        sharingManager.downloadAndCacheGPX(ownerUid: session.ownerUid, sessionId: session.sessionId) { url, error in
                            isDownloading = false
                            guard let url else {
                                downloadError = error ?? "Couldn't download this session's route."
                                return
                            }
                            onPick(ChosenLap(
                                ownerLabel: session.ownerName, trackName: session.trackName.isEmpty ? "Track Session" : session.trackName,
                                date: session.date, lapIndex: index, lapDurations: session.laps,
                                lapStartTimestamps: session.lapStartTimestamps, gpxFileURL: url
                            ))
                            dismiss()
                        }
                    }
                }
            }
        }
        .background(Color.prCardBg)
        .cornerRadius(14)
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.prBorder, lineWidth: 1))
    }

    // MARK: - Shared lap list (used by both tabs)
    private func lapList(count: Int, durations: [Double], bestTime: Double, onSelect: @escaping (Int) -> Void) -> some View {
        VStack(spacing: 0) {
            Divider().background(Color.prBorder)
            ForEach(0..<count, id: \.self) { index in
                let time = durations[index]
                Button(action: { onSelect(index) }) {
                    HStack {
                        Text("Lap \(index + 1)").font(.system(size: 13, weight: .medium)).foregroundColor(.prMuted)
                        Spacer()
                        if time == bestTime {
                            Image(systemName: "bolt.fill").font(.system(size: 10)).foregroundColor(Color(red: 0.180, green: 0.620, blue: 0.357))
                        }
                        Text(LapEngine.formatLapTime(time))
                            .font(.system(size: 13, weight: .bold, design: .monospaced))
                            .foregroundColor(time == bestTime ? Color(red: 0.180, green: 0.620, blue: 0.357) : .prInk)
                        Image(systemName: "chevron.right").font(.system(size: 10, weight: .bold)).foregroundColor(.prMuted)
                    }
                    .padding(.horizontal, 14).padding(.vertical, 10)
                }
                if index < count - 1 { Divider().background(Color.prBorder).padding(.leading, 14) }
            }
        }
    }
}

#Preview { LapCompareView() }
