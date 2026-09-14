import UIKit
import UserNotifications
import FirebaseCore
import FirebaseMessaging
import FirebaseAuth
import FirebaseDatabase
import GoogleMobileAds
import GoogleSignIn
import FBSDKCoreKit

// MARK: - App Delegate
// Handles push notification setup: asks permission, registers with Apple's
// push service (APNs), hands the device token to Firebase Cloud Messaging
// (FCM), and saves the resulting FCM token to the database so the Cloud
// Function (see the separate `packride-functions` deploy) knows where to
// send "your friend/community started riding" notifications.
//
// Firebase itself is configured here now (moved from PackRideApp's init())
// since this delegate's didFinishLaunching is the standard place for it once
// an AppDelegate is in play.
class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate, MessagingDelegate {

    // Aug 27, 2026 — lets a single full-screen view (MotoRunView, the Moto
    // Run mini-game) force landscape while the rest of the app stays
    // portrait-only. The project's UISupportedInterfaceOrientations_iPhone
    // build setting already allows Portrait + LandscapeLeft + LandscapeRight
    // at the OS level — this delegate method is what actually restricts
    // every other screen to portrait day-to-day. MotoRunView flips this to
    // .landscape on appear and back to .portrait on disappear.
    static var orientationLock = UIInterfaceOrientationMask.portrait

    func application(_ application: UIApplication, supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        AppDelegate.orientationLock
    }

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        FirebaseApp.configure()
        CrashFeedbackReporter.shared.start()
        ApplicationDelegate.shared.application(application, didFinishLaunchingWithOptions: launchOptions)

        // Starts up the Google Mobile Ads SDK — must happen before any
        // BannerAdView tries to load an ad (see AdManager.swift). Doesn't
        // itself show anything; ads only appear where BannerAdView is
        // actually placed (Ride Feed, Ride History, Profile).
        MobileAds.shared.start()

        Messaging.messaging().delegate = self
        UNUserNotificationCenter.current().delegate = self

        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .badge, .sound]) { granted, _ in
            guard granted else { return }
            DispatchQueue.main.async {
                application.registerForRemoteNotifications()
            }
        }
        return true
    }

    func application(_ app: UIApplication, open url: URL, options: [UIApplication.OpenURLOptionsKey: Any] = [:]) -> Bool {
        GIDSignIn.sharedInstance.handle(url) || ApplicationDelegate.shared.application(app, open: url, options: options)
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        Messaging.messaging().apnsToken = deviceToken
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        print("PackRide: failed to register for remote notifications — \(error.localizedDescription)")
    }

    // MARK: - FCM token
    // Firebase calls this whenever it (re)issues a token — first launch, after
    // a reinstall, token rotation, etc. We save it to two places because the
    // app uses two different identity schemes: Firebase Auth uid for the
    // follow/feed system (UserProfileManager, RideFeedManager), and the
    // device's identifierForVendor for communities (CommunityManager). See
    // the "Push Notifications" note in the handover doc for the full reason.
    func messaging(_ messaging: Messaging, didReceiveRegistrationToken fcmToken: String?) {
        guard let token = fcmToken else { return }
        UserDefaults.standard.set(token, forKey: "fcmToken")
        saveTokenToFirebase(token)
    }

    private func saveTokenToFirebase(_ token: String) {
        let db = Database.database().reference()

        // Auth-uid-keyed copy — used for solo-ride "your followers get notified" pushes.
        if let uid = Auth.auth().currentUser?.uid {
            let userRef = db.child("users").child(uid)
            userRef.child("fcmToken").setValue(token)
            let deviceID = UIDevice.current.identifierForVendor?.uuidString ?? UUID().uuidString
            userRef.child("fcmTokens").child("ios-\(deviceID)").setValue(token)
        }

        // Device-ID-keyed copy on every community membership record this
        // device belongs to — used for "someone in your community started
        // riding" pushes. Aug 21, 2026 — loops over
        // CommunityMembershipStore.allJoinedIDs() now that a device can
        // belong to more than one community, instead of a single stored ID.
        let deviceID = UIDevice.current.identifierForVendor?.uuidString ?? ""
        guard !deviceID.isEmpty else { return }
        for communityID in CommunityMembershipStore.allJoinedIDs() {
            db.child("communities").child(communityID).child("members").child(deviceID).child("fcmToken").setValue(token)
        }
    }

    // Show the notification banner/sound even while the app is open and in the foreground.
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification, withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound, .badge])
    }

    // Tapping a safety notification takes the recipient straight to the
    // responder inbox, where they can acknowledge and open the shared map.
    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse, withCompletionHandler completionHandler: @escaping () -> Void) {
        let info = response.notification.request.content.userInfo
        if info["packrideType"] as? String == "crashIncident" {
            UserDefaults.standard.set(info["incidentID"] as? String ?? "", forKey: "pendingCrashIncidentID")
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: .packRideCrashIncidentOpened, object: nil)
            }
        }
        completionHandler()
    }
}

extension Notification.Name {
    static let packRideCrashIncidentOpened = Notification.Name("packRideCrashIncidentOpened")
}
