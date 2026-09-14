import Foundation
import FirebaseAuth
import FirebaseCrashlytics
import FirebaseDatabase

/// Crashlytics owns the full symbolicated diagnostic. On the launch after a
/// fatal crash, this bridge sends a compact correlation code through the
/// existing append-only feedback channel so the developer is notified.
final class CrashFeedbackReporter {
    static let shared = CrashFeedbackReporter()

    private var authHandle: AuthStateDidChangeListenerHandle?
    private let pendingKey = "automaticCrashFeedbackPending"

    private init() {}

    func start() {
        if Crashlytics.crashlytics().didCrashDuringPreviousExecution() {
            UserDefaults.standard.set(true, forKey: pendingKey)
        }

        authHandle = Auth.auth().addStateDidChangeListener { [weak self] auth, user in
            guard let self, let user else { return }
            Crashlytics.crashlytics().setUserID(user.uid)
            guard UserDefaults.standard.bool(forKey: self.pendingKey) else {
                self.stopListening(to: auth)
                return
            }
            let code = "IOS-\(UUID().uuidString.prefix(10).uppercased())"
            let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
            let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown"
            let payload: [String: Any] = [
                "senderUID": user.uid,
                "senderName": "PackRide crash reporter",
                "senderEmail": "",
                "platform": "ios",
                "type": "automatic_crash",
                "errorCode": code,
                "appVersion": version,
                "appBuild": build,
                "message": "Automatic crash report \(code). Match the authenticated Firebase UID, app build, and report time in Crashlytics.",
                "createdAt": ServerValue.timestamp()
            ]
            Database.database().reference().child("feedback").childByAutoId().setValue(payload) { error, _ in
                guard error == nil else { return }
                UserDefaults.standard.set(false, forKey: self.pendingKey)
                self.stopListening(to: auth)
            }
        }
    }

    private func stopListening(to auth: Auth) {
        if let handle = authHandle {
            auth.removeStateDidChangeListener(handle)
            authHandle = nil
        }
    }
}
