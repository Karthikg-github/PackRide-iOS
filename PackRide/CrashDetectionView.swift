import SwiftUI
import CoreMotion
import Combine
import CoreLocation
import MessageUI

// MARK: - Crash Detection Manager
class CrashDetectionManager: NSObject, ObservableObject {
    private let motionManager = CMMotionManager()
    // Aug 27, 2026 — Grok battery/perf audit, fix #1: this used to own a
    // private CLLocationManager — a second live GPS instance running
    // kCLLocationAccuracyBest continuously alongside the app-wide
    // SharedLocationManager everything else uses, with the exact same
    // auto-start-on-authorization-change bug fixed in SharedLoactionManager.swift.
    // Now reads location off SharedLocationManager.shared instead, through the
    // same reason-counted startUpdating/stopUpdating(reason:) every other
    // screen uses — tagged "crashDetection" so SharedLocationManager's
    // accuracy tiering keeps navigation-grade accuracy active for as long as
    // monitoring is on (see SharedLoactionManager.navigationGradeReasons) —
    // and mirrors it into lastLocation via Combine so the two existing
    // consumers below (sendInAppCrashAlerts, and CrashDetectionView's SMS
    // composer) don't need to change at all.
    private let sharedLocation = SharedLocationManager.shared
    private var locationCancellable: AnyCancellable?
    // Automatic in-app alert path (CrashAlertManager.swift) — additional to,
    // never a replacement for, the SMS flow below. Only used to send, never
    // to listen (that's ProfileView's Crash Alerts card).
    private let crashAlertManager = CrashAlertManager()

    @Published var isMonitoring = false
    @Published var crashDetected = false
    @Published var countdownSeconds = 30
    @Published var currentGForce: Double = 0.0
    @Published var maxGForce: Double = 0.0
    @Published var lastLocation: CLLocation?
    @Published var emergencyAlertRequestID: UUID?

    private var countdownTimer: Timer?
    private var alertCancelled = false
    private let crashThreshold: Double = 4.0
    // Aug 27, 2026 — Grok re-review, small cleanup: currentGForce only ever
    // drives the live gauge in CrashDetectionView (grep-confirmed — nothing
    // else reads it), so publishing it at the full 10Hz sample rate was
    // triggering a SwiftUI re-render 10x/sec for a number nobody can read
    // that fast. Throttled to ~2Hz below; the crash-threshold check itself
    // (and maxGForce) still runs against every single sample, unthrottled —
    // only the UI-facing publish is slowed down.
    private var lastGForceUIUpdate: Date?

    // Aug 27, 2026 — Grok audit fix #5: the accelerometer callback below used
    // to be delivered `to: .main`, running every 10Hz sample directly on the
    // main thread. It now delivers to this dedicated background queue and
    // only hops to main for the @Published writes/crash trigger — the 10Hz
    // sampling rate itself is unchanged (this is the safety-critical crash
    // detector; lowering the rate isn't a tradeoff worth making here), only
    // where the work runs.
    private let motionQueue: OperationQueue = {
        let q = OperationQueue()
        q.name = "com.packride.crashDetection.motion"
        q.maxConcurrentOperationCount = 1
        q.qualityOfService = .userInitiated
        return q
    }()

    func startMonitoring() {
        guard motionManager.isAccelerometerAvailable else { return }

        isMonitoring = true
        locationCancellable = sharedLocation.$location
            .sink { [weak self] loc in self?.lastLocation = loc }
        // Aug 27, 2026 — Grok re-review: this used to be a plain
        // startUpdating(reason:), which only delivers location in the
        // foreground — if the screen locks (or the phone stays in a pocket,
        // exactly when a real crash is most likely), updates pause and the
        // process can eventually suspend, stopping the accelerometer too.
        // requestBackgroundUpdates keeps GPS (and by extension the app
        // itself) alive in the background while monitoring is on, the same
        // way an active ride or a Need Help broadcast already does.
        sharedLocation.requestBackgroundUpdates(reason: "crashDetection")

        motionManager.accelerometerUpdateInterval = 0.1
        motionManager.startAccelerometerUpdates(to: motionQueue) { [weak self] data, error in
            guard let self = self, let data = data else { return }

            let x = data.acceleration.x
            let y = data.acceleration.y
            let z = data.acceleration.z
            let gForce = sqrt(x*x + y*y + z*z)

            DispatchQueue.main.async {
                // Full-rate, every sample — this is the actual crash detector.
                if gForce > self.maxGForce {
                    self.maxGForce = gForce
                }
                if gForce > self.crashThreshold && !self.crashDetected {
                    self.triggerCrashAlert()
                }

                // UI-only, throttled to ~2Hz — see lastGForceUIUpdate above.
                let now = Date()
                if self.lastGForceUIUpdate == nil || now.timeIntervalSince(self.lastGForceUIUpdate!) >= 0.5 {
                    self.currentGForce = gForce
                    self.lastGForceUIUpdate = now
                }
            }
        }
    }

    func stopMonitoring() {
        motionManager.stopAccelerometerUpdates()
        sharedLocation.releaseBackgroundUpdates(reason: "crashDetection")
        locationCancellable?.cancel()
        locationCancellable = nil
        isMonitoring = false
        crashDetected = false
        currentGForce = 0.0
        maxGForce = 0.0
        lastGForceUIUpdate = nil
        cancelCountdown()
    }

    func triggerCrashAlert() {
        DispatchQueue.main.async {
            self.crashDetected = true
            self.countdownSeconds = 30
            self.alertCancelled = false
            self.startCountdown()
        }
    }

    func startCountdown() {
        countdownTimer?.invalidate()
        countdownTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            if self.countdownSeconds > 0 {
                self.countdownSeconds -= 1
            } else {
                self.sendEmergencyAlert()
                self.countdownTimer?.invalidate()
            }
        }
    }

    func cancelAlert() {
        alertCancelled = true
        crashDetected = false
        countdownSeconds = 30
        cancelCountdown()
    }

    func cancelCountdown() {
        countdownTimer?.invalidate()
        countdownTimer = nil
    }

    func sendEmergencyAlert() {
        DispatchQueue.main.async {
            self.emergencyAlertRequestID = UUID()
            self.crashDetected = false
            // Additional in-app path, alongside (not instead of) the SMS
            // composer CrashDetectionView presents in response to
            // emergencyAlertRequestID changing above.
            self.sendInAppCrashAlerts()
        }
    }

    // MARK: - Automatic in-app crash alerts (linked PackRide friends)
    // Runs alongside the existing SMS flow, never instead of it — every
    // emergency contact still gets the same SMS regardless of whether it's
    // linked. This only ADDITIONALLY writes to Firebase for whichever
    // contacts have a linkedUserID set (see EmergencyContact in
    // ProfileView.swift), since a bare phone number has no PackRide uid to
    // notify in-app. Reads the same "emergencyContacts" UserDefaults key
    // ProfileView's Emergency Contacts card saves to — as of Aug 27, 2026
    // that's also the exact same key CrashDetectionView's own SMS flow reads
    // (see CrashDetectionView's emergencyContacts @State), so there's one
    // list feeding both the SMS composer and this in-app path everywhere.
    private func sendInAppCrashAlerts() {
        let linkedIDs = Self.loadLinkedEmergencyContactIDs()
        let riderName = UserDefaults.standard.string(forKey: "riderName") ?? ""
        let senderName = riderName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "A PackRide rider" : riderName
        // GroupRideView persists the active code while the live room is open.
        // A linked contact in that roster is marked as the primary responder;
        // other riders remain a useful redundant notification path.
        let activeRideCode = UserDefaults.standard.string(forKey: "activeRideCode")
        crashAlertManager.createCrashIncident(
            senderName: senderName,
            coordinate: lastLocation?.coordinate,
            peakG: maxGForce,
            groupRideCode: activeRideCode,
            primaryResponderUIDs: linkedIDs
        ) { _, _ in
            // The trusted Cloud Function writes recipient inbox entries after
            // it validates and fans out the incident. Keeping that write on
            // the server means a rider never receives permission to write
            // directly into another user's /users/{uid} tree.
        }
    }

    private static func loadLinkedEmergencyContactIDs() -> [String] {
        guard let data = UserDefaults.standard.data(forKey: "emergencyContacts"),
              let decoded = try? JSONDecoder().decode([EmergencyContact].self, from: data)
        else { return [] }
        return decoded.compactMap { $0.linkedUserID }.filter { !$0.isEmpty }
    }

    func simulateCrash() {
        triggerCrashAlert()
    }
}

// MARK: - Crash Detection View
struct CrashDetectionView: View {
    @StateObject private var crashManager = CrashDetectionManager()
    // Aug 27, 2026 — bug fix: this used to keep its own separate
    // emergencyContact1/emergencyContact2 @AppStorage strings, entirely
    // disconnected from the [EmergencyContact] list ProfileView's Emergency
    // Contacts card manages. Editing a contact in one place never showed up
    // in the other. Now both screens read/write the exact same
    // "emergencyContacts" UserDefaults array (via the shared EmergencyContact
    // model in ProfileView.swift) and reuse the same add/edit sheet, so a
    // change made here or in Profile is immediately the same data everywhere
    // — there's only ever one list.
    // Aug 27, 2026 — Grok re-review, small cleanup: this used to be its own
    // private UserProfileManager() — a duplicate instance alongside
    // PackRideApp's app-wide one (injected via .environmentObject; see
    // PackRideApp.swift), same bug class already fixed for ActiveSoloRideView
    // in the previous pass. CrashDetectionView is only ever pushed from
    // ContentView (see ContentView.swift's NavigationLink), which already has
    // the shared instance in its environment, so this just needed the same
    // @EnvironmentObject swap.
    @EnvironmentObject private var profileManager: UserProfileManager
    @State private var emergencyContacts: [EmergencyContact] = []
    @State private var showAddContact = false
    @State private var editingContact: EmergencyContact? = nil
    @State private var showEmergencyMessageComposer = false
    @State private var showNoEmergencyContactsAlert = false
    @State private var showTextUnavailableAlert = false
    @State private var emergencyMessageRecipients: [String] = []

    var gForceColor: Color {
        if crashManager.currentGForce < 2 { return Color(red: 0.180, green: 0.620, blue: 0.357) }
        if crashManager.currentGForce < 3 { return .prCoral }
        return Color(red: 0.827, green: 0.231, blue: 0.173)
    }

    var body: some View {
        ZStack {
            Color.prBg.ignoresSafeArea()

            ScrollView(showsIndicators: false) {
                VStack(spacing: 0) {
                    protectionHero

                    if crashManager.isMonitoring {
                        liveMonitorSection
                    }

                    emergencyContactsSection
                    howItWorksSection

                    Color.clear.frame(height: 34)
                }
            }
            .ignoresSafeArea(edges: .top)

            if crashManager.crashDetected {
                CrashAlertOverlay(
                    countdown: crashManager.countdownSeconds,
                    onCancel: { crashManager.cancelAlert() },
                    onSendNow: { crashManager.sendEmergencyAlert() }
                )
                .zIndex(10)
            }
        }
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
        .onAppear {
            loadEmergencyContacts()
            profileManager.listenForFollowedUsers()
        }
        .onDisappear {
            profileManager.stopListeningForFollowedUsers()
        }
        .sheet(isPresented: $showAddContact) {
            AddContactSheet(
                existing: editingContact,
                followedUsers: profileManager.followedUsers,
                onSave: { contact in
                    if let idx = emergencyContacts.firstIndex(where: { $0.id == contact.id }) {
                        emergencyContacts[idx] = contact
                    } else {
                        emergencyContacts.append(contact)
                    }
                    saveEmergencyContacts()
                    showAddContact = false
                },
                onCancel: { showAddContact = false }
            )
        }
        .sheet(isPresented: $showEmergencyMessageComposer) {
            EmergencyMessageComposer(
                recipients: emergencyMessageRecipients,
                message: emergencyAlertMessage(),
                onFinish: { showEmergencyMessageComposer = false; emergencyMessageRecipients = [] }
            )
        }
        .alert("No Emergency Contacts", isPresented: $showNoEmergencyContactsAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Add at least one emergency contact before relying on crash alerts.")
        }
        .alert("Text Message Unavailable", isPresented: $showTextUnavailableAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("This device is not configured to send text messages.")
        }
        .onChange(of: crashManager.emergencyAlertRequestID) { _, requestID in
            guard requestID != nil else { return }
            presentEmergencyMessageComposer()
        }
    }

    // MARK: - Web-style sections
    private var protectionHero: some View {
        ZStack(alignment: .bottomLeading) {
            LinearGradient(
                colors: [Color.prInkFixed, Color.prBg],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .center, spacing: 12) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("SAFETY")
                            .font(.system(size: 11, weight: .heavy))
                            .tracking(3)
                            .foregroundColor(.prCoral)
                        Text("Crash Detection")
                            .font(.system(size: 30, weight: .bold))
                            .foregroundColor(.white)
                    }

                    Spacer()

                    ZStack {
                        Circle()
                            .fill(crashManager.isMonitoring ? Color(red: 0.180, green: 0.620, blue: 0.357).opacity(0.18) : Color.white.opacity(0.10))
                            .frame(width: 48, height: 48)
                        Image(systemName: crashManager.isMonitoring ? "shield.fill" : "shield.slash.fill")
                            .font(.system(size: 20, weight: .semibold))
                            .foregroundColor(crashManager.isMonitoring ? Color(red: 0.373, green: 0.851, blue: 0.541) : .white.opacity(0.55))
                    }
                }

                Text(crashManager.isMonitoring ? "Protection is active" : "Protection is currently off")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(crashManager.isMonitoring ? Color(red: 0.373, green: 0.851, blue: 0.541) : .white.opacity(0.62))
                    .padding(.top, 18)

                Text(crashManager.isMonitoring ?
                     "PackRide is monitoring impact forces while you ride." :
                     "Turn protection on before you head out. PackRide will monitor impact forces in the background.")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(.white.opacity(0.72))
                    .lineSpacing(4)
                    .padding(.top, 6)
                    .fixedSize(horizontal: false, vertical: true)

                Button(action: {
                    if crashManager.isMonitoring { crashManager.stopMonitoring() }
                    else { crashManager.startMonitoring() }
                }) {
                    HStack(spacing: 10) {
                        Image(systemName: crashManager.isMonitoring ? "stop.circle.fill" : "shield.checkered")
                            .font(.system(size: 16, weight: .bold))
                        Text(crashManager.isMonitoring ? "Disable Protection" : "Enable Protection")
                            .font(.system(size: 15, weight: .bold))
                        Spacer()
                        Image(systemName: "arrow.right")
                            .font(.system(size: 12, weight: .bold))
                    }
                    .foregroundColor(crashManager.isMonitoring ? .white : Color.prInkFixed)
                    .padding(.horizontal, 16)
                    .frame(height: 54)
                    .background(crashManager.isMonitoring ? Color(red: 0.827, green: 0.231, blue: 0.173) : Color.prCoral)
                    .clipShape(RoundedRectangle(cornerRadius: 16))
                }
                .padding(.top, 22)
            }
            .padding(.horizontal, 20)
            .padding(.top, 54)
            .padding(.bottom, 26)
        }
        .frame(minHeight: 292)
    }

    private var liveMonitorSection: some View {
        VStack(spacing: 0) {
            crashWebSectionLabel(title: "LIVE MONITOR", trailing: "4.0G THRESHOLD")

            VStack(spacing: 0) {
                HStack(spacing: 0) {
                    crashMetric(value: String(format: "%.1fG", crashManager.currentGForce), label: "Current", tint: gForceColor)
                    Rectangle().fill(Color.prBorder).frame(width: 1, height: 54)
                    crashMetric(value: String(format: "%.1fG", crashManager.maxGForce), label: "Max", tint: .prCoral)
                }
                .padding(.vertical, 10)

                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(Color.white.opacity(0.10))
                            .frame(height: 10)

                        Capsule()
                            .fill(gForceColor)
                            .frame(
                                width: min(geo.size.width * CGFloat(max(crashManager.currentGForce, 0) / 6.0), geo.size.width),
                                height: 10
                            )
                            .animation(.easeOut(duration: 0.1), value: crashManager.currentGForce)

                        Rectangle()
                            .fill(Color.prCoral)
                            .frame(width: 2, height: 18)
                            .offset(x: geo.size.width * CGFloat(4.0 / 6.0) - 1)
                    }
                }
                .frame(height: 18)
                .padding(.horizontal, 4)

                Button(action: { crashManager.simulateCrash() }) {
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                        Text("Run Test Alert")
                        Spacer()
                        Image(systemName: "arrow.up.right")
                    }
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.prCoral)
                    .padding(.top, 18)
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 20)
        }
        .background(Color.prInkFixed)
        .overlay(Rectangle().fill(Color.white.opacity(0.08)).frame(height: 1), alignment: .bottom)
    }

    private var emergencyContactsSection: some View {
        VStack(spacing: 0) {
            crashWebSectionLabel(title: "EMERGENCY NETWORK", trailing: "\(emergencyContacts.count)/3")

            VStack(spacing: 0) {
                if emergencyContacts.isEmpty {
                    crashContactRow(label: "Emergency Contact", value: "", onTap: {
                        editingContact = nil
                        showAddContact = true
                    })
                } else {
                    ForEach(Array(emergencyContacts.enumerated()), id: \.element.id) { index, contact in
                        if index > 0 { crashDivider }
                        crashContactRow(
                            label: index == 0 ? "Primary Contact" : "Contact \(index + 1)",
                            value: "\(contact.name) — \(contact.phone)",
                            onTap: { editingContact = contact; showAddContact = true },
                            onDelete: { deleteContact(contact) }
                        )
                    }

                    if emergencyContacts.count < 3 {
                        crashDivider
                        crashContactRow(label: "Add Contact", value: "", onTap: {
                            editingContact = nil
                            showAddContact = true
                        })
                    }
                }
            }
            .background(Color.prCardBg)
        }
    }

    private var howItWorksSection: some View {
        VStack(spacing: 0) {
            crashWebSectionLabel(title: "HOW IT WORKS", trailing: "AUTOMATIC")

            VStack(spacing: 0) {
                crashStep(number: "01", title: "Monitor", text: "The app watches G-force from your iPhone accelerometer while protection is active.")
                crashDivider
                crashStep(number: "02", title: "Detect", text: "An impact above 4G starts a 30-second safety countdown.")
                crashDivider
                crashStep(number: "03", title: "Confirm", text: "Cancel the alert when you're okay, or send immediately when you need help.")
                crashDivider
                crashStep(number: "04", title: "Notify", text: "Your emergency contacts receive a message with your latest available GPS location.")
            }
            .background(Color.prCardBg)
        }
    }

    private func crashWebSectionLabel(title: String, trailing: String? = nil) -> some View {
        HStack(alignment: .center) {
            Text(title)
                .font(.system(size: 11, weight: .heavy))
                .foregroundColor(.prMuted)
                .tracking(2)
            Spacer()
            if let trailing {
                Text(trailing)
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(.prCoral)
                    .tracking(1.1)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 18)
        .padding(.bottom, 8)
    }

    private func crashMetric(value: String, label: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(value)
                .font(.system(size: 28, weight: .bold, design: .monospaced))
                .foregroundColor(.white)
            Text(label)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.white.opacity(0.52))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .leading) {
            Rectangle().fill(tint).frame(width: 3).padding(.vertical, 5)
        }
        .padding(.leading, 12)
    }

    private func crashContactRow(label: String, value: String, onTap: @escaping () -> Void, onDelete: (() -> Void)? = nil) -> some View {
        HStack(spacing: 10) {
            Button(action: onTap) {
                HStack(spacing: 14) {
                    ZStack {
                        Circle()
                            .fill(value.isEmpty ? Color.prCoralSoft : Color(red: 0.180, green: 0.620, blue: 0.357).opacity(0.14))
                            .frame(width: 42, height: 42)
                        Image(systemName: value.isEmpty ? "plus" : "person.fill")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundColor(value.isEmpty ? .prCoral : Color(red: 0.180, green: 0.620, blue: 0.357))
                    }

                    VStack(alignment: .leading, spacing: 3) {
                        Text(label.uppercased())
                            .font(.system(size: 10, weight: .heavy))
                            .tracking(1)
                            .foregroundColor(.prMuted)
                        Text(value.isEmpty ? "Add an emergency contact" : value)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(value.isEmpty ? .prMuted : .prInk)
                            .lineLimit(1)
                    }

                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.prMuted.opacity(0.65))
                }
            }
            .buttonStyle(.plain)

            if let onDelete {
                Button(action: onDelete) {
                    Image(systemName: "trash")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(Color(red: 0.827, green: 0.231, blue: 0.173))
                        .padding(8)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }

    private var crashDivider: some View {
        Rectangle().fill(Color.prBorder).frame(height: 1).padding(.leading, 72)
    }

    private func crashStep(number: String, title: String, text: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Text(number)
                .font(.system(size: 11, weight: .heavy, design: .monospaced))
                .foregroundColor(.prCoral)
                .frame(width: 42, alignment: .leading)

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.prInk)
                Text(text)
                    .font(.system(size: 12, weight: .regular))
                    .foregroundColor(.prMuted)
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 16)
    }

    private func presentEmergencyMessageComposer() {
        let recipients = emergencyContactPhoneNumbers()
        guard !recipients.isEmpty else { showNoEmergencyContactsAlert = true; return }
        guard MFMessageComposeViewController.canSendText() else { showTextUnavailableAlert = true; return }
        emergencyMessageRecipients = recipients
        showEmergencyMessageComposer = true
    }

    private func emergencyContactPhoneNumbers() -> [String] {
        emergencyContacts.map { $0.phone.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }

    // MARK: - Shared Emergency Contacts store
    // Same "emergencyContacts" UserDefaults key and EmergencyContact model as
    // ProfileView's Emergency Contacts card — see the comment on this view's
    // @State declarations above.
    private func loadEmergencyContacts() {
        if let data = UserDefaults.standard.data(forKey: "emergencyContacts"),
           let decoded = try? JSONDecoder().decode([EmergencyContact].self, from: data) {
            emergencyContacts = decoded
        }
    }
    private func saveEmergencyContacts() {
        if let encoded = try? JSONEncoder().encode(emergencyContacts) {
            UserDefaults.standard.set(encoded, forKey: "emergencyContacts")
        }
    }
    private func deleteContact(_ contact: EmergencyContact) {
        emergencyContacts.removeAll { $0.id == contact.id }
        saveEmergencyContacts()
    }

    private func emergencyAlertMessage() -> String {
        if let coordinate = crashManager.lastLocation?.coordinate {
            return "Crash detected. I may need emergency help. My current location is https://maps.apple.com/?ll=\(coordinate.latitude),\(coordinate.longitude)"
        }
        return "Crash detected. I may need emergency help. My location is not currently available."
    }
}

// MARK: - Crash Alert Overlay
struct CrashAlertOverlay: View {
    let countdown: Int
    let onCancel: () -> Void
    let onSendNow: () -> Void

    var body: some View {
        ZStack {
            // Aug 24, 2026 — was `Color.prInk.opacity(0.97)`. .prInk is the
            // app's ADAPTIVE primary-text token (near-black in light mode,
            // near-white in dark mode — see LoginView.swift's Color
            // extension) — using it as a background happened to look right
            // in light mode by coincidence, but flipped this screen to a
            // near-white backdrop with white text on it (illegible) whenever
            // the rider had Dark Mode on in Profile. This alert is meant to
            // be a fixed, always-dark emergency overlay regardless of the
            // app's theme — same intentional pattern as the RECORDING RIDE/
            // LIVE HUD badges elsewhere, and matches the RN reference
            // screen's own hardcoded rgba(19,17,15,0.97) backdrop exactly —
            // so this is now a literal fixed color, not a theme token.
            Color(red: 0.0745, green: 0.0667, blue: 0.0588).opacity(0.97).ignoresSafeArea()

            VStack(spacing: 28) {
                ZStack {
                    Circle().fill(Color(red: 0.827, green: 0.231, blue: 0.173).opacity(0.2)).frame(width: 120, height: 120)
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 56))
                        .foregroundColor(Color(red: 1.0, green: 0.353, blue: 0.271))
                }

                VStack(spacing: 10) {
                    Text("Crash Detected!")
                        .font(.system(size: 26, weight: .bold))
                        .foregroundColor(.white)
                    Text("Are you okay? Emergency text\nopens in \(countdown) seconds.")
                        .font(.system(size: 15))
                        .foregroundColor(.white.opacity(0.6))
                        .multilineTextAlignment(.center)
                }

                ZStack {
                    Circle().stroke(Color.white.opacity(0.15), lineWidth: 8).frame(width: 100, height: 100)
                    Circle()
                        .trim(from: 0, to: CGFloat(countdown) / 30)
                        .stroke(Color(red: 1.0, green: 0.353, blue: 0.271), style: StrokeStyle(lineWidth: 8, lineCap: .round))
                        .frame(width: 100, height: 100)
                        .rotationEffect(.degrees(-90))
                        .animation(.linear(duration: 1), value: countdown)
                    Text("\(countdown)")
                        .font(.system(size: 32, weight: .bold, design: .monospaced))
                        .foregroundColor(.white)
                }

                VStack(spacing: 12) {
                    Button(action: onCancel) {
                        Text("I'm Okay — Cancel Alert")
                            .font(.system(size: 16, weight: .bold))
                            // Same fix as the backdrop above — .prInk would
                            // flip this to white-on-green in dark mode.
                            // Fixed dark text, matching RN's hardcoded
                            // #1C1A17 here.
                            .foregroundColor(Color(red: 0.110, green: 0.102, blue: 0.090))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 17)
                            .background(Color(red: 0.373, green: 0.851, blue: 0.541))
                            .cornerRadius(15)
                    }

                    Button(action: onSendNow) {
                        Text("Send Alert Now")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(Color(red: 1.0, green: 0.353, blue: 0.271))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                            .background(Color(red: 1.0, green: 0.353, blue: 0.271).opacity(0.12))
                            .cornerRadius(15)
                    }
                }
                .padding(.horizontal, 24)
            }
        }
    }
}

// MARK: - Contact Row
struct ContactRow: View {
    let label: String
    let value: String
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 14) {
                ZStack {
                    Circle()
                        .fill(value.isEmpty ? Color.prCoralSoft : Color(red: 0.891, green: 0.965, blue: 0.918))
                        .frame(width: 44, height: 44)
                    Image(systemName: value.isEmpty ? "plus" : "person.fill")
                        .font(.system(size: 16))
                        .foregroundColor(value.isEmpty ? .prCoral : Color(red: 0.180, green: 0.620, blue: 0.357))
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text(label)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.prMuted)
                    Text(value.isEmpty ? "Add contact" : value)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(value.isEmpty ? .prMuted : .prInk)
                        .lineLimit(1)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.prMuted)
            }
            .padding(14)
            .background(Color.prFieldBg)
            .cornerRadius(14)
        }
    }
}

// MARK: - How It Works Row
struct HowItWorksRow: View {
    let number: String
    let text: String

    var body: some View {
        HStack(spacing: 14) {
            ZStack {
                Circle().fill(Color.prCoral).frame(width: 28, height: 28)
                Text(number).font(.system(size: 12, weight: .bold)).foregroundColor(.white)
            }
            Text(text)
                .font(.system(size: 13))
                .foregroundColor(.prMuted)
                .lineSpacing(3)
        }
    }
}

// MARK: - Emergency Message Composer
struct EmergencyMessageComposer: UIViewControllerRepresentable {
    let recipients: [String]
    let message: String
    let onFinish: () -> Void

    func makeUIViewController(context: Context) -> MFMessageComposeViewController {
        let composer = MFMessageComposeViewController()
        composer.messageComposeDelegate = context.coordinator
        composer.recipients = recipients
        composer.body = message
        return composer
    }

    func updateUIViewController(_ uiViewController: MFMessageComposeViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onFinish: onFinish) }

    final class Coordinator: NSObject, MFMessageComposeViewControllerDelegate {
        let onFinish: () -> Void
        init(onFinish: @escaping () -> Void) { self.onFinish = onFinish }
        func messageComposeViewController(_ controller: MFMessageComposeViewController, didFinishWith result: MessageComposeResult) {
            controller.dismiss(animated: true) { self.onFinish() }
        }
    }
}

// Aug 27, 2026 — the old EmergencyContactPicker/AddContactView pair that
// used to live here (backing the now-removed emergencyContact1/2
// @AppStorage strings) was deleted as part of the sync fix above.
// ProfileView.swift's AddContactSheet + ContactPickerView do the same job
// against the shared EmergencyContact list and are reused here instead —
// see CrashDetectionView's .sheet(isPresented: $showAddContact) above.

#Preview {
    NavigationView { CrashDetectionView() }
        .environmentObject(UserProfileManager())
}
