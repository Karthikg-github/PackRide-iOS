import SwiftUI

// MARK: - Lean Calibration Badge
//
// Aug 24, 2026 — Karthik's question: "we put an info tab to calibrate it to
// zero. but how do the user know its calibrated to 0?" Until this pass there
// was genuinely no way to tell: currentLeanAngle defaults to 0 before
// calibration runs, and the zeroed reading also reads as 0 once it has, so
// "not calibrated yet" and "calibrated, currently upright" looked identical
// on screen. See the matching Aug 24, 2026 comments next to leanZeroOffset/
// leanCalibrated in ActiveSoloRideView.startLeanAngleMonitoring,
// TurnByTurnView.startLeanAngleMonitoring, and
// LapModeView.ActiveLapView.startMotionCapture for the companion fix: the
// zero point is now the average of several consecutive readings (~1s),
// rather than a single possibly-noisy first sample, and each of those
// screens exposes that ~1s window via a new `isLeanCalibrating` flag. This
// badge is the other half — it turns that flag into a real
// "Calibrating…" -> "Calibrated" confirmation instead of leaving the rider
// to guess whether anything happened.
//
// A small transient HUD badge, not a permanent stat: shows "Calibrating
// lean angle…" for that ~1s settle window, then flips to a brief "Calibrated
// to your mount" confirmation before fading away on its own — it doesn't
// stay on screen competing for space with speed/distance for the rest of
// the ride, since lean angle itself isn't shown live anywhere in this app
// today (only afterward, via maxLeanAngle in Ride Summary and the GPX
// telemetry). This badge's only job is to answer "did it work," once, right
// when it matters.
//
// Plain hardcoded white-on-dark styling (not theme-driven — no DesignSystem
// colors) to match every other live-ride HUD badge in this app (the "LIVE"
// badge in ActiveSoloRideView, "RECORDING RIDE" in TurnByTurnView,
// "LAPPING" in LapModeView) — these overlays sit on top of a live map
// regardless of the app's light/dark setting, so they intentionally don't
// follow it.
//
// Takes a single `isCalibrating` Bool and derives its own phase/timer state
// internally — the three screens above just flip one flag and this view
// handles the rest, same shape as the calibrating -> confirming -> hidden
// state machine this pattern was ported from.
struct LeanCalibrationBadge: View {
    let isCalibrating: Bool

    private enum Phase: Equatable {
        case calibrating
        case confirming
        case hidden
    }

    // How long the "Calibrated to your mount" confirmation stays up before
    // auto-hiding.
    private static let confirmationVisibleSeconds: Double = 5.0

    @State private var phase: Phase
    @State private var wasCalibrating: Bool

    init(isCalibrating: Bool) {
        self.isCalibrating = isCalibrating
        _phase = State(initialValue: isCalibrating ? .calibrating : .hidden)
        _wasCalibrating = State(initialValue: isCalibrating)
    }

    var body: some View {
        Group {
            switch phase {
            case .hidden:
                // No badge, no reserved layout space — same as returning nil.
                EmptyView()
            case .calibrating:
                badge(text: "Keep phone still · calibrating lean angle…") {
                    PulsingDot()
                }
                .padding(.top, 8)
            case .confirming:
                badge(text: "Calibrated to your mount") {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 13))
                        .foregroundColor(Color(red: 0.298, green: 0.851, blue: 0.392))
                }
                .padding(.top, 8)
            }
        }
        .onChange(of: isCalibrating) { _, newValue in
            let wasPreviouslyCalibrating = wasCalibrating
            wasCalibrating = newValue
            if newValue {
                phase = .calibrating
                return
            }
            guard wasPreviouslyCalibrating else { return }
            // Just finished calibrating — flash the confirmation, then hide.
            phase = .confirming
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.confirmationVisibleSeconds) {
                // Only hide if we're still showing the confirmation this timer
                // was scheduled for — guards against a stale timer firing after
                // a brand-new calibration cycle already started again (e.g. the
                // rider ended and restarted the ride while this badge was still
                // fading out).
                if phase == .confirming {
                    phase = .hidden
                }
            }
        }
    }

    @ViewBuilder
    private func badge<Icon: View>(text: String, @ViewBuilder icon: () -> Icon) -> some View {
        HStack(spacing: 6) {
            icon()
            Text(text)
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .foregroundColor(.white)
                .tracking(0.5)
        }
        .padding(.horizontal, 10).padding(.vertical, 5)
        .background(Color.black.opacity(0.5))
        .clipShape(Capsule())
    }
}

// Small pulsing amber dot for the "still calibrating" state — same solid-dot
// construction as the other HUD badges (LIVE, RECORDING RIDE, LAPPING) but
// animated to read as "in progress" rather than "recording."
private struct PulsingDot: View {
    @State private var isDim = false

    var body: some View {
        Circle()
            .fill(Color(red: 0.949, green: 0.663, blue: 0.231))
            .frame(width: 7, height: 7)
            .opacity(isDim ? 0.35 : 1)
            .animation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true), value: isDim)
            .onAppear { isDim = true }
    }
}
