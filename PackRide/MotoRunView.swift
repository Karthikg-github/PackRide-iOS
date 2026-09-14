import SwiftUI
import UIKit
import Combine

// MARK: - Moto Run — hidden mini-game
// Aug 27, 2026 — Karthik's take on Chrome's offline dino game: tap the
// "PACKRIDE" wordmark on the Home hero card (see ContentView.swift) to open
// this, tap to jump the motorcycle over speed bumps, speed ramps up the
// longer you survive. Deliberately self-contained — its own game loop, no
// dependency on any ride-tracking manager — so it can never interfere with
// real app state. High score persists via @AppStorage("motoRunHighScore"),
// the same key ContentView reads to show "Moto Run best" under Top Speed
// Ever on the hero card once there's a score to show.
//
// Aug 27, 2026 (v2) — sprite/landscape/speed-ramp fixes, see the git log —
// followed by (v3): a refresh-icon restart with a 3-second countdown
// instead of tap-to-restart.
//
// Aug 27, 2026 (v4) — multiplayer. Tap "Invite" (top right, solo ready
// screen only) to race up to 2 friends: same speed bumps, same seed, three
// lanes stacked vertically. See MotoRunSession.swift for the sync design
// (nobody's obstacles are ever sent over the network — only a shared seed
// and each rider's own jump/score/alive state). Solo mode below is
// untouched from v3; multiplayer is a fully separate code path gated on
// `session.raceState == .idle`, so nothing about the working solo game
// risked changing here.
struct MotoRunView: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage("motoRunHighScore") private var highScore: Int = 0
    @AppStorage("riderName") private var riderName: String = "Rider"
    @AppStorage("motoRunColorIndex") private var myColorIndex: Int = 0

    private enum GameState { case ready, playing, gameOver, countdown }

    @State private var gameState: GameState = .ready
    @State private var playerY: CGFloat = 0          // 0 = grounded, negative = airborne
    @State private var velocity: CGFloat = 0
    @State private var isLeaning = false
    @State private var obstacles: [Obstacle] = []
    @State private var score: Int = 0
    @State private var speed: CGFloat = 3.2
    @State private var distanceSinceSpawn: CGFloat = 0
    @State private var nextSpawnDistance: CGFloat = 420
    @State private var justScoredBest = false
    @State private var countdownFramesRemaining: Int = 0

    private let groundHeight: CGFloat = 56
    private let playerWidth: CGFloat = 50
    private let playerHeight: CGFloat = 44
    private let playerX: CGFloat = 90
    private let gravity: CGFloat = 0.9
    private let jumpVelocity: CGFloat = -14

    private let baseSpeed: CGFloat = 3.2
    private let maxSpeed: CGFloat = 11
    private let speedRampPerPoint: CGFloat = 0.0028

    private let timer = Timer.publish(every: 1.0 / 60.0, on: .main, in: .common).autoconnect()
    private let jumpHaptic = UIImpactFeedbackGenerator(style: .light)
    private let crashHaptic = UINotificationFeedbackGenerator()

    // MARK: - Multiplayer state
    @StateObject private var session = MotoRunSessionManager()
    @State private var showLobby = false
    @State private var joinCodeInput = ""
    @State private var joinError: String? = nil

    // Per-rider simulation state, keyed by device ID — the same
    // gravity/jump math as solo mode, just tracked per lane. My own lane's
    // `alive`/`score` are tracked locally (mpLocalAlive/mpLocalScore) so my
    // own HUD is instant rather than waiting on a network round trip;
    // everyone else's lane trusts their broadcast state.
    @State private var laneY: [String: CGFloat] = [:]
    @State private var laneVelocity: [String: CGFloat] = [:]
    @State private var laneLeaning: [String: Bool] = [:]
    @State private var knownJumpCount: [String: Int] = [:]
    @State private var mpObstacleXs: [Double] = []
    @State private var mpSchedule: RaceObstacleSchedule? = nil
    @State private var mpScoreTickCounter = 0
    @State private var mpLocalScore = 0
    @State private var mpLocalAlive = true
    @State private var hasReportedFinish = false
    // `session.elapsed` is a plain wall-clock computation, not @Published —
    // nothing forces SwiftUI to re-render just because time passed. Once
    // racing starts, the per-tick @State writes below (mpObstacleXs, laneY,
    // etc.) drive re-renders naturally; during the pre-race countdown none
    // of those fire yet, so this dummy counter is mutated every tick purely
    // to force the "3, 2, 1" overlay to re-evaluate against fresh elapsed
    // time instead of freezing on whatever it first showed.
    @State private var mpCountdownTick = 0

    private let mpGroundHeight: CGFloat = 20
    private let mpPlayerWidth: CGFloat = 34
    private let mpPlayerHeight: CGFloat = 30
    private let mpPlayerX: CGFloat = 56
    private let mpObstacleWidth: CGFloat = 18
    private let mpObstacleHeight: CGFloat = 15

    private var myInitials: String { riderName.rideInitials }

    private struct Obstacle: Identifiable {
        let id = UUID()
        var x: CGFloat
        let width: CGFloat = 26
        let height: CGFloat = 22
    }

    var body: some View {
        // Aug 27, 2026 — Karthik pointed out every other pre/post-activity
        // screen in the app carries the AdBannerFooter (see AdManager.swift
        // — Ride Feed, Ride History, Profile) and Moto Run was missing it.
        // Reserving a fixed strip for it in this outer VStack, rather than
        // overlaying it on top of the game area, means the GeometryReader
        // below reports a correspondingly smaller size and every position
        // solo/multiplayer already computes relative to geo.size just
        // naturally leaves room — no gameplay math needed to change for
        // either mode.
        VStack(spacing: 0) {
            GeometryReader { geo in
                ZStack {
                    Color.prBg.ignoresSafeArea()

                    if session.raceState == .idle {
                        soloPlayfield(in: geo)
                    } else {
                        multiplayerPlayfield(in: geo)
                    }

                    topBar
                }
                .contentShape(Rectangle())
                .onTapGesture { handleTap() }
                .onReceive(timer) { _ in
                    if session.raceState == .idle {
                        tick(in: geo.size)
                    } else {
                        multiplayerTick(in: geo.size)
                    }
                }
            }
            AdBannerFooter()
        }
        .background(Color.prBg.ignoresSafeArea())
        .onAppear { MotoRunView.lockOrientation(.landscapeRight) }
        .onDisappear {
            MotoRunView.lockOrientation(.portrait)
            session.leaveRace()
        }
        .sheet(isPresented: $showLobby) {
            MotoRunLobbyView(
                session: session,
                myInitials: myInitials,
                myColorIndex: $myColorIndex,
                joinCodeInput: $joinCodeInput,
                joinError: $joinError
            )
        }
        .onChange(of: session.raceState) { _, newState in
            if newState != .lobby { showLobby = false }
        }
        .onChange(of: session.raceStartAt) { _, newValue in
            if newValue > 0 { resetMultiplayerRunState() }
        }
    }

    // MARK: - Orientation lock
    private static func lockOrientation(_ mask: UIInterfaceOrientationMask) {
        AppDelegate.orientationLock = mask
        guard let scene = UIApplication.shared.connectedScenes.first(where: { $0.activationState == .foregroundActive }) as? UIWindowScene else { return }
        scene.requestGeometryUpdate(.iOS(interfaceOrientations: mask)) { _ in }
        scene.windows.first?.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
    }

    // MARK: - Top bar
    private var topBar: some View {
        VStack {
            HStack {
                Button(action: { dismiss() }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 22))
                        .foregroundColor(.prMuted)
                }
                Spacer()
                if session.raceState == .idle {
                    if gameState == .ready {
                        Button(action: { showLobby = true }) {
                            HStack(spacing: 6) {
                                Image(systemName: "person.2.fill")
                                Text("Invite")
                            }
                            .font(.system(size: 13, weight: .bold))
                            .foregroundColor(.white)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(Color.prCoral)
                            .clipShape(Capsule())
                        }
                        .padding(.trailing, 10)
                    }
                    VStack(alignment: .trailing, spacing: 2) {
                        Text("\(score)")
                            .font(.system(size: 20, weight: .bold, design: .rounded))
                            .foregroundColor(.prInk)
                        Text("BEST \(highScore)")
                            .font(.system(size: 11, weight: .heavy))
                            .tracking(1.2)
                            .foregroundColor(.prMuted)
                    }
                }
            }
            .padding(.horizontal, 24)
            .padding(.top, 10)
            Spacer()
        }
    }

    // MARK: - Solo mode (unchanged from v3)

    private func soloPlayfield(in geo: GeometryProxy) -> some View {
        ZStack {
            VStack {
                Spacer()
                Rectangle()
                    .fill(Color.prBorder)
                    .frame(height: 2)
                    .padding(.bottom, groundHeight)
            }

            ForEach(obstacles) { obstacle in
                SpeedBumpShape()
                    .fill(Color.prTeal)
                    .frame(width: obstacle.width, height: obstacle.height)
                    .position(x: obstacle.x, y: geo.size.height - groundHeight - obstacle.height / 2)
            }

            MotorcycleSprite(leaning: isLeaning)
                .frame(width: playerWidth, height: playerHeight)
                .position(x: playerX, y: geo.size.height - groundHeight - playerHeight / 2 + playerY)

            if gameState != .playing {
                overlay
            }
        }
    }

    private var countdownSecondsDisplay: Int {
        max(1, (countdownFramesRemaining + 59) / 60)
    }

    private var overlay: some View {
        VStack(spacing: 14) {
            switch gameState {
            case .ready:
                Image(systemName: "hand.tap.fill")
                    .font(.system(size: 34))
                    .foregroundColor(.prCoral)
                Text("Moto Run")
                    .font(.system(size: 24, weight: .bold, design: .rounded))
                    .foregroundColor(.prInk)
                Text("Tap to jump the speed bumps")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(.prMuted)
            case .gameOver:
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 34))
                    .foregroundColor(.prCoral)
                Text("Wiped Out")
                    .font(.system(size: 24, weight: .bold, design: .rounded))
                    .foregroundColor(.prInk)
                Text(justScoredBest ? "New best — \(score)" : "Score \(score) · Best \(highScore)")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(.prMuted)
                Button(action: { beginCountdown() }) {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 20, weight: .bold))
                        .foregroundColor(.white)
                        .frame(width: 52, height: 52)
                        .background(Color.prCoral)
                        .clipShape(Circle())
                }
                .padding(.top, 4)
            case .countdown:
                Text("Get Ready")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.prMuted)
                Text("\(countdownSecondsDisplay)")
                    .font(.system(size: 56, weight: .bold, design: .rounded))
                    .foregroundColor(.prCoral)
                    .id(countdownSecondsDisplay)
                    .transition(.scale.combined(with: .opacity))
                    .animation(.easeOut(duration: 0.2), value: countdownSecondsDisplay)
            case .playing:
                EmptyView()
            }
        }
        .padding(28)
        .background(Color.prCardBg)
        .overlay(RoundedRectangle(cornerRadius: 20).stroke(Color.prBorder, lineWidth: 1))
        .cornerRadius(20)
    }

    private func handleTap() {
        if session.raceState == .idle {
            switch gameState {
            case .ready:
                start()
            case .playing:
                jump()
            case .gameOver, .countdown:
                break
            }
        } else if session.raceState == .active, session.elapsed >= 0 {
            multiplayerJump()
        }
    }

    private func resetRunState() {
        obstacles = []
        score = 0
        speed = baseSpeed
        playerY = 0
        velocity = 0
        distanceSinceSpawn = 0
        nextSpawnDistance = 420
        justScoredBest = false
    }

    private func start() {
        resetRunState()
        gameState = .playing
    }

    private func beginCountdown() {
        resetRunState()
        countdownFramesRemaining = 3 * 60
        gameState = .countdown
    }

    private func jump() {
        guard playerY == 0 else { return }
        velocity = jumpVelocity
        jumpHaptic.impactOccurred()
    }

    private func tick(in size: CGSize) {
        if gameState == .countdown {
            countdownFramesRemaining -= 1
            if countdownFramesRemaining <= 0 {
                gameState = .playing
            }
            return
        }
        guard gameState == .playing else { return }

        if playerY != 0 || velocity != 0 {
            velocity += gravity
            playerY = min(0, playerY + velocity)
            if playerY >= 0 { playerY = 0; velocity = 0 }
        }
        isLeaning = playerY < -4

        score += 1
        speed = min(baseSpeed + CGFloat(score) * speedRampPerPoint, maxSpeed)

        distanceSinceSpawn += speed
        if distanceSinceSpawn >= nextSpawnDistance {
            distanceSinceSpawn = 0
            nextSpawnDistance = CGFloat.random(in: 300...460)
            obstacles.append(Obstacle(x: size.width + 20))
        }
        for i in obstacles.indices { obstacles[i].x -= speed }
        obstacles.removeAll { $0.x < -40 }

        let hitboxWidth = playerWidth - 18
        let hitboxHeight = playerHeight - 14
        let playerCenterY = size.height - groundHeight - playerHeight / 2 + playerY
        let playerFrame = CGRect(
            x: playerX - hitboxWidth / 2,
            y: playerCenterY - hitboxHeight / 2,
            width: hitboxWidth,
            height: hitboxHeight
        )
        for obstacle in obstacles {
            let obstacleFrame = CGRect(
                x: obstacle.x - obstacle.width / 2,
                y: size.height - groundHeight - obstacle.height,
                width: obstacle.width,
                height: obstacle.height
            )
            if playerFrame.intersects(obstacleFrame) {
                gameOver()
                return
            }
        }
    }

    private func gameOver() {
        gameState = .gameOver
        crashHaptic.notificationOccurred(.warning)
        if score > highScore {
            highScore = score
            justScoredBest = true
        }
    }

    // MARK: - Multiplayer mode

    private func resetMultiplayerRunState() {
        laneY = [:]
        laneVelocity = [:]
        laneLeaning = [:]
        knownJumpCount = [:]
        mpObstacleXs = []
        mpSchedule = nil
        mpScoreTickCounter = 0
        mpLocalScore = 0
        mpLocalAlive = true
        hasReportedFinish = false
        mpCountdownTick = 0
    }

    private var multiplayerRaceIsOver: Bool {
        guard session.raceState == .active, session.raceStartAt > 0, session.elapsed >= 0 else { return false }
        if session.elapsed >= MotoRacePhysics.maxDuration { return true }
        guard !session.racers.isEmpty else { return false }
        return session.racers.allSatisfy { racer in
            racer.id == session.myID ? !mpLocalAlive : !racer.alive
        }
    }

    private func multiplayerJump() {
        guard mpLocalAlive, (laneY[session.myID] ?? 0) == 0 else { return }
        laneVelocity[session.myID] = jumpVelocity
        session.sendJump()
        jumpHaptic.impactOccurred()
    }

    private func multiplayerPlayfield(in geo: GeometryProxy) -> some View {
        let racers = session.racers
        let laneHeight = racers.isEmpty ? geo.size.height : geo.size.height / CGFloat(racers.count)

        return ZStack {
            VStack(spacing: 0) {
                ForEach(Array(racers.enumerated()), id: \.element.id) { index, racer in
                    MotoLaneView(
                        racer: racer,
                        isMe: racer.id == session.myID,
                        laneWidth: geo.size.width,
                        laneHeight: laneHeight,
                        obstacleXs: mpObstacleXs,
                        playerY: laneY[racer.id] ?? 0,
                        isLeaning: laneLeaning[racer.id] ?? false,
                        displayScore: racer.id == session.myID ? mpLocalScore : racer.score,
                        displayAlive: racer.id == session.myID ? mpLocalAlive : racer.alive,
                        groundHeight: mpGroundHeight,
                        playerWidth: mpPlayerWidth,
                        playerHeight: mpPlayerHeight,
                        playerX: mpPlayerX,
                        obstacleWidth: mpObstacleWidth,
                        obstacleHeight: mpObstacleHeight
                    )
                    if index < racers.count - 1 {
                        Rectangle().fill(Color.prBorder).frame(height: 1)
                    }
                }
            }

            if session.raceStartAt > 0, session.elapsed < 0 {
                countdownOverlay
            } else if multiplayerRaceIsOver {
                resultsOverlay
            }
        }
    }

    private var countdownOverlay: some View {
        let secs = max(1, Int(ceil(-session.elapsed)))
        return VStack(spacing: 10) {
            Text("Get Ready")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.prMuted)
            Text("\(secs)")
                .font(.system(size: 56, weight: .bold, design: .rounded))
                .foregroundColor(.prCoral)
                .id(secs)
                .transition(.scale.combined(with: .opacity))
                .animation(.easeOut(duration: 0.2), value: secs)
        }
        .padding(28)
        .background(Color.prCardBg)
        .overlay(RoundedRectangle(cornerRadius: 20).stroke(Color.prBorder, lineWidth: 1))
        .cornerRadius(20)
    }

    private func medal(for index: Int) -> String {
        switch index {
        case 0: return "🥇"
        case 1: return "🥈"
        case 2: return "🥉"
        default: return ""
        }
    }

    private var resultsOverlay: some View {
        let ranked = session.racers
            .map { r -> (MotoRacer, Int) in (r, r.id == session.myID ? mpLocalScore : r.score) }
            .sorted { $0.1 > $1.1 }

        return VStack(spacing: 12) {
            Image(systemName: "flag.checkered")
                .font(.system(size: 28))
                .foregroundColor(.prCoral)
            Text("Race Over")
                .font(.system(size: 20, weight: .bold, design: .rounded))
                .foregroundColor(.prInk)

            VStack(spacing: 8) {
                ForEach(Array(ranked.enumerated()), id: \.offset) { index, entry in
                    HStack(spacing: 10) {
                        Text(medal(for: index)).font(.system(size: 15))
                        ZStack {
                            Circle().fill(entry.0.color).frame(width: 22, height: 22)
                            Text(entry.0.initials).font(.system(size: 9, weight: .bold)).foregroundColor(.white)
                        }
                        Text(entry.0.id == session.myID ? "You" : entry.0.initials)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(.prInk)
                        Spacer()
                        Text("\(entry.1)")
                            .font(.system(size: 14, weight: .bold, design: .rounded))
                            .foregroundColor(.prMuted)
                    }
                }
            }
            .padding(.horizontal, 6)

            if session.isHost {
                Button(action: { session.startRace() }) {
                    Text("Play Again")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 11)
                        .background(Color.prCoral)
                        .clipShape(Capsule())
                }
            } else {
                Text("Waiting for host to restart…")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.prMuted)
            }

            Button(action: { session.leaveRace() }) {
                Text("Leave")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.prMuted)
            }
            .padding(.top, 2)
        }
        .padding(22)
        .frame(maxWidth: 300)
        .background(Color.prCardBg)
        .overlay(RoundedRectangle(cornerRadius: 20).stroke(Color.prBorder, lineWidth: 1))
        .cornerRadius(20)
    }

    private func multiplayerTick(in size: CGSize) {
        guard session.raceState == .active else { return }
        if mpSchedule == nil, session.seed > 0 {
            mpSchedule = RaceObstacleSchedule.generate(seed: session.seed)
        }
        let elapsed = session.elapsed
        guard elapsed >= 0 else {
            mpCountdownTick += 1   // see the property's comment — keeps the countdown overlay live
            return
        }
        guard let schedule = mpSchedule else { return }

        let racerCount = max(session.racers.count, 1)
        let laneHeight = size.height / CGFloat(racerCount)
        mpObstacleXs = schedule.visibleObstacleX(at: elapsed, laneWidth: size.width)

        for racer in session.racers {
            let alive = racer.id == session.myID ? mpLocalAlive : racer.alive
            guard alive else { continue }

            var y = laneY[racer.id] ?? 0
            var v = laneVelocity[racer.id] ?? 0

            if racer.id != session.myID {
                let lastKnownJump = knownJumpCount[racer.id] ?? racer.jumpCount
                if racer.jumpCount > lastKnownJump, y == 0 {
                    v = jumpVelocity
                }
                knownJumpCount[racer.id] = racer.jumpCount
            }

            if y != 0 || v != 0 {
                v += gravity
                y = min(0, y + v)
                if y >= 0 { y = 0; v = 0 }
            }
            laneY[racer.id] = y
            laneVelocity[racer.id] = v
            laneLeaning[racer.id] = y < -3
        }

        if mpLocalAlive, elapsed < MotoRacePhysics.maxDuration {
            let hitboxWidth = mpPlayerWidth - 12
            let hitboxHeight = mpPlayerHeight - 10
            let myY = laneY[session.myID] ?? 0
            let centerY = laneHeight - mpGroundHeight - mpPlayerHeight / 2 + myY
            let playerFrame = CGRect(
                x: mpPlayerX - hitboxWidth / 2,
                y: centerY - hitboxHeight / 2,
                width: hitboxWidth,
                height: hitboxHeight
            )
            var crashed = false
            for x in mpObstacleXs {
                let obstacleFrame = CGRect(
                    x: CGFloat(x) - mpObstacleWidth / 2,
                    y: laneHeight - mpGroundHeight - mpObstacleHeight,
                    width: mpObstacleWidth,
                    height: mpObstacleHeight
                )
                if playerFrame.intersects(obstacleFrame) { crashed = true; break }
            }

            if crashed {
                mpLocalAlive = false
                crashHaptic.notificationOccurred(.warning)
                session.sendCrash(finalScore: mpLocalScore)
            } else {
                mpLocalScore += 1
                mpScoreTickCounter += 1
                if mpScoreTickCounter % 10 == 0 {
                    session.sendScore(mpLocalScore)
                }
            }
        }

        if multiplayerRaceIsOver, !hasReportedFinish {
            hasReportedFinish = true
            if mpLocalAlive {
                session.sendTimeoutFinish(finalScore: mpLocalScore)
            }
        }
    }
}

// MARK: - Multiplayer lane
// One rider's row in the stacked 3-lane race view — the same obstacle
// x-positions (`obstacleXs`) are passed to every lane unchanged, since
// they're identical everywhere (see RaceObstacleSchedule); only the bike's
// color, jump state, and alive/score status differ per lane.
private struct MotoLaneView: View {
    let racer: MotoRacer
    let isMe: Bool
    let laneWidth: CGFloat
    let laneHeight: CGFloat
    let obstacleXs: [Double]
    let playerY: CGFloat
    let isLeaning: Bool
    let displayScore: Int
    let displayAlive: Bool
    let groundHeight: CGFloat
    let playerWidth: CGFloat
    let playerHeight: CGFloat
    let playerX: CGFloat
    let obstacleWidth: CGFloat
    let obstacleHeight: CGFloat

    var body: some View {
        ZStack {
            Color.prBg

            if displayAlive {
                Rectangle()
                    .fill(Color.prBorder)
                    .frame(height: 1)
                    .position(x: laneWidth / 2, y: laneHeight - groundHeight)

                ForEach(Array(obstacleXs.enumerated()), id: \.offset) { _, x in
                    SpeedBumpShape()
                        .fill(Color.prTeal)
                        .frame(width: obstacleWidth, height: obstacleHeight)
                        .position(x: CGFloat(x), y: laneHeight - groundHeight - obstacleHeight / 2)
                }

                MotorcycleSprite(leaning: isLeaning, tankColor: racer.color)
                    .frame(width: playerWidth, height: playerHeight)
                    .position(x: playerX, y: laneHeight - groundHeight - playerHeight / 2 + playerY)

                HStack(spacing: 8) {
                    avatarBadge
                    Text("\(displayScore)")
                        .font(.system(size: 13, weight: .bold, design: .rounded))
                        .foregroundColor(.prInk)
                    if isMe {
                        Text("YOU")
                            .font(.system(size: 8, weight: .heavy))
                            .tracking(1)
                            .foregroundColor(.prCoral)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color.prCardBg.opacity(0.92))
                .clipShape(Capsule())
                .position(x: 62, y: 16)
            } else {
                HStack(spacing: 10) {
                    avatarBadge
                    VStack(alignment: .leading, spacing: 1) {
                        Text("\(racer.initials) — Wiped Out")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundColor(.prMuted)
                        Text("Score \(displayScore)")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(.prMuted.opacity(0.8))
                    }
                    Spacer()
                }
                .padding(.horizontal, 16)
            }
        }
        .frame(width: laneWidth, height: laneHeight)
        .clipped()
    }

    private var avatarBadge: some View {
        ZStack {
            Circle().fill(racer.color).frame(width: 24, height: 24)
            Text(racer.initials)
                .font(.system(size: 9, weight: .bold))
                .foregroundColor(.white)
        }
    }
}

// MARK: - Invite / lobby sheet
private struct MotoRunLobbyView: View {
    @ObservedObject var session: MotoRunSessionManager
    let myInitials: String
    @Binding var myColorIndex: Int
    @Binding var joinCodeInput: String
    @Binding var joinError: String?
    @Environment(\.dismiss) private var dismiss
    @State private var showJoinField = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                if session.raceCode.isEmpty {
                    startOrJoinChoice
                } else {
                    lobbyDetails
                }
                Spacer()
            }
            .padding(20)
            .background(Color.prBg.ignoresSafeArea())
            .navigationTitle("Moto Run")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Close") {
                        if session.raceState == .lobby { session.leaveRace() }
                        dismiss()
                    }
                }
            }
        }
    }

    private var startOrJoinChoice: some View {
        VStack(spacing: 14) {
            Image(systemName: "person.2.fill")
                .font(.system(size: 30))
                .foregroundColor(.prCoral)
                .padding(.top, 20)
            Text("Race Friends")
                .font(.system(size: 20, weight: .bold, design: .rounded))
                .foregroundColor(.prInk)
            Text("Up to 3 riders, same speed bumps, same start.")
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(.prMuted)
                .multilineTextAlignment(.center)

            Button(action: { session.createRace(initials: myInitials, colorIndex: myColorIndex) }) {
                Text("Start a Race")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(Color.prCoral)
                    .cornerRadius(14)
            }
            .padding(.top, 8)

            if showJoinField {
                VStack(spacing: 10) {
                    TextField("Enter code", text: $joinCodeInput)
                        .font(.system(size: 18, weight: .bold, design: .rounded))
                        .multilineTextAlignment(.center)
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                        .padding(.vertical, 12)
                        .background(Color.prFieldBg)
                        .cornerRadius(12)
                    if let joinError {
                        Text(joinError)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(.prCoral)
                    }
                    Button(action: joinTapped) {
                        Text("Join")
                            .font(.system(size: 15, weight: .bold))
                            .foregroundColor(.prCoral)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                            .background(Color.prCoralSoft)
                            .cornerRadius(14)
                    }
                    .disabled(joinCodeInput.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            } else {
                Button(action: { showJoinField = true }) {
                    Text("Join with a Code")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundColor(.prCoral)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(Color.prCoralSoft)
                        .cornerRadius(14)
                }
            }
        }
    }

    private func joinTapped() {
        let code = joinCodeInput.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard !code.isEmpty else { return }
        joinError = nil
        session.joinRace(code: code, initials: myInitials, colorIndex: myColorIndex)
    }

    private var lobbyDetails: some View {
        VStack(spacing: 18) {
            VStack(spacing: 6) {
                Text("RACE CODE")
                    .font(.system(size: 10, weight: .heavy))
                    .tracking(2)
                    .foregroundColor(.prMuted)
                Text(session.raceCode)
                    .font(.system(size: 34, weight: .bold, design: .rounded))
                    .tracking(4)
                    .foregroundColor(.prInk)
            }
            .padding(.top, 16)

            Button(action: shareCode) {
                HStack(spacing: 8) {
                    Image(systemName: "square.and.arrow.up")
                    Text("Invite a Friend")
                }
                .font(.system(size: 14, weight: .bold))
                .foregroundColor(.white)
                .padding(.horizontal, 18)
                .padding(.vertical, 10)
                .background(Color.prCoral)
                .clipShape(Capsule())
            }

            colorPicker

            VStack(alignment: .leading, spacing: 10) {
                Text("RIDERS (\(session.racers.count)/3)")
                    .font(.system(size: 10, weight: .heavy))
                    .tracking(1.5)
                    .foregroundColor(.prMuted)
                ForEach(session.racers) { racer in
                    HStack(spacing: 10) {
                        ZStack {
                            Circle().fill(racer.color).frame(width: 28, height: 28)
                            Text(racer.initials).font(.system(size: 11, weight: .bold)).foregroundColor(.white)
                        }
                        Text(racer.id == session.myID ? "You" : racer.initials)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(.prInk)
                        if racer.isHost {
                            Text("HOST")
                                .font(.system(size: 9, weight: .heavy))
                                .tracking(1)
                                .foregroundColor(.prCoral)
                        }
                        Spacer()
                    }
                }
            }
            .padding(16)
            .background(Color.prCardBg)
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.prBorder, lineWidth: 1))
            .cornerRadius(16)

            if session.isHost {
                Button(action: { session.startRace() }) {
                    Text(session.racers.count >= 2 ? "Start Race" : "Waiting for a friend to join…")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(session.racers.count >= 2 ? Color.prCoral : Color.prMuted)
                        .cornerRadius(14)
                }
                .disabled(session.racers.count < 2)
            } else {
                Text("Waiting for the host to start the race…")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(.prMuted)
            }
        }
    }

    private var colorPicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("YOUR BIKE COLOR")
                .font(.system(size: 10, weight: .heavy))
                .tracking(1.5)
                .foregroundColor(.prMuted)
            HStack(spacing: 10) {
                ForEach(Array(MotoBikeColor.palette.enumerated()), id: \.offset) { index, color in
                    Button(action: {
                        myColorIndex = index
                        session.updateMyColor(index)
                    }) {
                        Circle()
                            .fill(color)
                            .frame(width: 30, height: 30)
                            .overlay(Circle().stroke(Color.prInk, lineWidth: myColorIndex == index ? 2 : 0))
                    }
                }
            }
        }
    }

    private func shareCode() {
        let text = "Race me in Moto Run on PackRide! \u{1F3CE}\nCode: \(session.raceCode)\n\nDon't have the app? https://apps.apple.com/app/id6772399785"
        let av = UIActivityViewController(activityItems: [text], applicationActivities: nil)
        if let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
           let vc = scene.windows.first?.rootViewController { vc.present(av, animated: true) }
    }
}

// MARK: - Motorcycle sprite
// A side-profile silhouette built from simple primitives (no hand-tuned
// bezier path) so it stays legible at small sizes: two wheels with hubs, a
// tank, a rear frame strut, a forward-raked fork, and a handlebar riser +
// bar. All positions are local offsets from the view's own center, using
// the shared `strut` helper below to draw a rotated capsule between two
// points rather than hand-picking rotation angles. `tankColor` lets each
// multiplayer rider's bike show their chosen color; solo mode leaves it at
// the default coral.
private struct MotorcycleSprite: View {
    let leaning: Bool
    var tankColor: Color = .prCoral

    var body: some View {
        ZStack {
            strut(from: CGPoint(x: -17, y: 9), to: CGPoint(x: -25, y: 12), width: 4, color: .prMuted)
            strut(from: CGPoint(x: -17, y: 9), to: CGPoint(x: -13, y: -3), width: 5, color: .prInk)
            strut(from: CGPoint(x: 9, y: -9), to: CGPoint(x: 17, y: 9), width: 5, color: .prInk)
            strut(from: CGPoint(x: 9, y: -9), to: CGPoint(x: 16, y: -20), width: 4, color: .prInk)
            strut(from: CGPoint(x: 9, y: -20), to: CGPoint(x: 22, y: -19), width: 4, color: .prInk)

            Ellipse()
                .fill(tankColor)
                .frame(width: 26, height: 12)
                .rotationEffect(.degrees(-10))
                .offset(x: -2, y: -6)

            Circle()
                .fill(Color.prCardBg)
                .frame(width: 6, height: 6)
                .overlay(Circle().stroke(Color.prInk, lineWidth: 1))
                .offset(x: 22, y: -13)

            wheel(x: -17)
            wheel(x: 17)
        }
        .rotationEffect(.degrees(leaning ? -10 : 0), anchor: .bottom)
        .animation(.easeOut(duration: 0.15), value: leaning)
    }

    private func wheel(x: CGFloat) -> some View {
        ZStack {
            Circle().fill(Color.prInk).frame(width: 18, height: 18)
            Circle().fill(Color.prCardBg).frame(width: 7, height: 7)
        }
        .offset(x: x, y: 9)
    }

    private func strut(from a: CGPoint, to b: CGPoint, width: CGFloat, color: Color) -> some View {
        let dx = b.x - a.x
        let dy = b.y - a.y
        let length = sqrt(dx * dx + dy * dy)
        let angle = atan2(dy, dx)
        let mid = CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
        return Capsule()
            .fill(color)
            .frame(width: length, height: width)
            .rotationEffect(.radians(angle))
            .offset(x: mid.x, y: mid.y)
    }
}

private struct SpeedBumpShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX, y: rect.maxY),
            control: CGPoint(x: rect.midX, y: rect.minY)
        )
        path.closeSubpath()
        return path
    }
}

#Preview {
    MotoRunView()
}
