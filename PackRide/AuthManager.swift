import Foundation
import FirebaseCore
import FirebaseAuth
import FirebaseDatabase
import FirebaseStorage
import UIKit
import Combine
import AuthenticationServices
import CryptoKit
import GoogleSignIn
import FBSDKLoginKit

final class AuthManager: NSObject, ObservableObject {
    @Published var isLoggedIn: Bool = false
    @Published var isLoading: Bool = true
    @Published var errorMessage: String = ""

    private var authStateHandle: AuthStateDidChangeListenerHandle?
    private var appleNonce: String?

    override init() {
        super.init()
        authStateHandle = Auth.auth().addStateDidChangeListener { [weak self] _, user in
            guard let self = self else { return }

            if let uid = user?.uid {
                // A fresh install (or a login on a different phone) starts
                // with hasCompletedOnboarding == false locally regardless of
                // whether THIS account already has a profile — that mismatch
                // is why a reinstall always sent an existing rider back
                // through Onboarding, and why their name/bike/city/avatar/
                // banner looked wiped even though publishProfile had them
                // safely on the server the whole time. Check the server
                // before deciding this is a new rider.
                self.hydrateLocalProfileIfNeeded(uid: uid) {
                    DispatchQueue.main.async {
                        self.isLoggedIn = true
                        self.isLoading = false
                    }
                }
            } else {
                DispatchQueue.main.async {
                    self.isLoggedIn = false
                    self.isLoading = false
                }
            }
            // The push-notification FCM token can arrive before login finishes
            // (it's cached in UserDefaults the moment Firebase issues it — see
            // NotificationManager.swift). Once we know who's logged in, make
            // sure that cached token actually lands under this user's record.
            if let uid = user?.uid,
               let token = UserDefaults.standard.string(forKey: "fcmToken"),
               !token.isEmpty {
                let userRef = Database.database().reference().child("users").child(uid)
                userRef.child("fcmToken").setValue(token)
                let deviceID = UIDevice.current.identifierForVendor?.uuidString ?? UUID().uuidString
                userRef.child("fcmTokens").child("ios-\(deviceID)").setValue(token)
            }
            // Records this device's ID under the signed-in account so the
            // Firebase rules can recognize content authored under the older
            // device-ID identity scheme (from before this account was signed
            // in, or from before login was required) as still belonging to
            // this same person — that mismatch is why deleting some older
            // Feed posts was silently rejected by the server even though the
            // app considered them "yours" and showed the delete button.
            if let uid = user?.uid, let deviceID = UIDevice.current.identifierForVendor?.uuidString {
                Database.database().reference().child("users").child(uid).child("deviceID").setValue(deviceID)
            }
        }
    }

    deinit {
        if let authStateHandle {
            Auth.auth().removeStateDidChangeListener(authStateHandle)
        }
    }

    // MARK: - Restore profile after reinstall / new-device login (Aug 27, 2026)
    //
    // hasCompletedOnboarding, riderName, riderBike, riderCity, riderExperience,
    // avatarURL, and bannerURL all used to live only in local @AppStorage
    // (UserDefaults) — never re-fetched from Firebase after login. Reinstalling
    // (or signing into the same account on a new phone) reset all of that
    // locally, so the app always treated it as a brand-new rider and sent them
    // through Onboarding again, even though publishProfile() had already
    // written their real name/bike/city/experience/avatar/banner to
    // users/{uid}/profile on the server (see UserProfileManager.publishProfile,
    // called from ProfileView's Save and from HomeView's onAppear right after
    // Onboarding completes). This runs once per sign-in, before the splash
    // screen hands off to either Onboarding or ContentView: if this account
    // already has a server-side profile, it restores it locally and marks
    // onboarding complete so the rider lands straight in the app; if not,
    // it's a genuinely new account and Onboarding runs as normal.
    private func hydrateLocalProfileIfNeeded(uid: String, completion: @escaping () -> Void) {
        // Only worth checking when THIS device doesn't already think
        // onboarding is done — if it does, whatever's in UserDefaults right
        // now is presumably already correct and current for this account, so
        // don't let a stale server read stomp a live in-app edit on launch.
        guard !UserDefaults.standard.bool(forKey: "hasCompletedOnboarding") else {
            completion()
            return
        }

        var didFinish = false
        let finish = {
            guard !didFinish else { return }
            didFinish = true
            completion()
        }

        // Don't let a slow or offline network hang the splash screen —
        // fall back to a normal (empty) Onboarding flow if Firebase hasn't
        // answered within a few seconds, same as it always has for a
        // genuinely new sign-in.
        DispatchQueue.main.asyncAfter(deadline: .now() + 6) { finish() }

        Database.database().reference().child("users").child(uid).child("profile")
            .observeSingleEvent(of: .value) { snapshot in
                defer { finish() }
                guard let data = snapshot.value as? [String: Any],
                      let name = data["name"] as? String, !name.isEmpty else { return }

                let defaults = UserDefaults.standard
                defaults.set(name, forKey: "riderName")
                if let bike = data["bike"] as? String { defaults.set(bike, forKey: "riderBike") }
                if let city = data["city"] as? String { defaults.set(city, forKey: "riderCity") }
                if let experience = data["experience"] as? String { defaults.set(experience, forKey: "riderExperience") }
                if let avatar = data["avatarURL"] as? String, !avatar.isEmpty { defaults.set(avatar, forKey: "avatarURL") }
                if let banner = data["bannerURL"] as? String, !banner.isEmpty { defaults.set(banner, forKey: "bannerURL") }
                // This account already has a profile on the server, so this
                // is a reinstall/new-device sign-in, not a genuinely new
                // rider — skip Onboarding and go straight into the app with
                // the restored profile.
                defaults.set(true, forKey: "hasCompletedOnboarding")
            }
    }

    func login(email: String, password: String) {
        errorMessage = ""
        Auth.auth().signIn(withEmail: email, password: password) { [weak self] _, error in
            DispatchQueue.main.async {
                if let error = error {
                    self?.errorMessage = self?.friendlyError(error) ?? error.localizedDescription
                }
            }
        }
    }

    func register(email: String, password: String) {
        errorMessage = ""
        Auth.auth().createUser(withEmail: email, password: password) { [weak self] _, error in
            DispatchQueue.main.async {
                if let error = error {
                    self?.errorMessage = self?.friendlyError(error) ?? error.localizedDescription
                }
            }
        }
    }

    // MARK: - Social sign-in
    // All three providers exchange their identity token for a Firebase
    // credential. Firebase creates a profile for a first-time provider login
    // or restores that provider's existing user record on later sign-ins.
    func signInWithGoogle() {
        errorMessage = ""
        guard let clientID = FirebaseApp.app()?.options.clientID, !clientID.isEmpty else {
            errorMessage = "Google sign-in isn't configured yet. Download the updated GoogleService-Info.plist after enabling Google in Firebase."
            return
        }
        guard let presenting = presentingViewController else {
            errorMessage = "Couldn't present Google sign-in. Please try again."
            return
        }

        GIDSignIn.sharedInstance.configuration = GIDConfiguration(clientID: clientID)
        GIDSignIn.sharedInstance.signIn(withPresenting: presenting) { [weak self] result, error in
            if let error {
                self?.publish(error: error)
                return
            }
            guard let user = result?.user,
                  let idToken = user.idToken?.tokenString else {
                self?.setError("Google didn't return a sign-in token. Please try again.")
                return
            }
            let credential = GoogleAuthProvider.credential(
                withIDToken: idToken,
                accessToken: user.accessToken.tokenString
            )
            self?.signIn(with: credential)
        }
    }

    func signInWithFacebook() {
        errorMessage = ""
        guard Bundle.main.object(forInfoDictionaryKey: "FacebookAppID") as? String != nil else {
            errorMessage = "Facebook sign-in isn't configured yet. Add the Meta app ID and enable Facebook in Firebase first."
            return
        }
        guard let presenting = presentingViewController else {
            errorMessage = "Couldn't present Facebook sign-in. Please try again."
            return
        }

        LoginManager().logIn(permissions: ["public_profile", "email"], from: presenting) { [weak self] result, error in
            if let error {
                self?.publish(error: error)
                return
            }
            guard result?.isCancelled != true,
                  let accessToken = AccessToken.current?.tokenString else {
                return
            }
            self?.signIn(with: FacebookAuthProvider.credential(withAccessToken: accessToken))
        }
    }

    func signInWithApple() {
        errorMessage = ""
        let nonce = Self.randomNonce()
        appleNonce = nonce

        let request = ASAuthorizationAppleIDProvider().createRequest()
        request.requestedScopes = [.fullName, .email]
        request.nonce = Self.sha256(nonce)

        let controller = ASAuthorizationController(authorizationRequests: [request])
        controller.delegate = self
        controller.presentationContextProvider = self
        controller.performRequests()
    }

    func resetPassword(email: String, completion: @escaping (Bool) -> Void) {
        errorMessage = ""
        Auth.auth().sendPasswordReset(withEmail: email) { [weak self] error in
            DispatchQueue.main.async {
                if let error = error {
                    self?.errorMessage = self?.friendlyError(error) ?? error.localizedDescription
                    completion(false)
                } else {
                    completion(true)
                }
            }
        }
    }

    func signOut() {
        try? Auth.auth().signOut()
    }

    private var presentingViewController: UIViewController? {
        guard let windowScene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState == .foregroundActive }),
              let root = windowScene.windows.first(where: { $0.isKeyWindow })?.rootViewController else { return nil }
        return root.topMostViewController
    }

    private func signIn(with credential: AuthCredential) {
        Auth.auth().signIn(with: credential) { [weak self] _, error in
            if let error { self?.publish(error: error) }
        }
    }

    private func publish(error: Error) {
        DispatchQueue.main.async { self.errorMessage = self.friendlyError(error) }
    }

    private func setError(_ message: String) {
        DispatchQueue.main.async { self.errorMessage = message }
    }

    private static func randomNonce(length: Int = 32) -> String {
        let charset = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVXYZabcdefghijklmnopqrstuvwxyz-._")
        var randomBytes = [UInt8](repeating: 0, count: length)
        guard SecRandomCopyBytes(kSecRandomDefault, randomBytes.count, &randomBytes) == errSecSuccess else {
            return UUID().uuidString
        }
        return String(randomBytes.map { charset[Int($0) % charset.count] })
    }

    private static func sha256(_ input: String) -> String {
        SHA256.hash(data: Data(input.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Delete Account
    // Apple requires apps that support account creation to also offer account
    // deletion in-app (App Store Review Guideline 5.1.1(v)) — this wasn't built
    // yet before now. Removes this user's primary data node in Firebase, then
    // deletes synchronized profile/media/history and the Firebase Auth account.
    func deleteAccount(completion: @escaping (String?) -> Void) {
        guard let user = Auth.auth().currentUser else {
            completion("No signed-in account found.")
            return
        }
        let uid = user.uid
        if let lastSignIn = user.metadata.lastSignInDate,
           Date().timeIntervalSince(lastSignIn) > 5 * 60 {
            completion("For your security, sign out and sign back in before deleting your account.")
            return
        }
        let db = Database.database().reference()
        let storage = Storage.storage().reference()
        let group = DispatchGroup()

        // Remove authored public posts and their images before the auth user
        // disappears. Missing objects are harmless and do not block deletion.
        group.enter()
        db.child("feedPosts").queryOrdered(byChild: "authorID").queryEqual(toValue: uid)
            .observeSingleEvent(of: .value, with: { snapshot in
                let postGroup = DispatchGroup()
                for post in snapshot.children.allObjects as? [DataSnapshot] ?? [] {
                    let postID = post.key
                    postGroup.enter()
                    db.child("feedPosts").child(postID).removeValue { _, _ in postGroup.leave() }
                    storage.child("feedPhotos/\(postID).jpg").delete(completion: nil)
                }
                postGroup.notify(queue: .main) { group.leave() }
            }, withCancel: { _ in group.leave() })

        for path in ["users/\(uid)", "publicRiders/\(uid)", "helpRequests/\(uid)"] {
            group.enter()
            db.child(path).removeValue { _, _ in group.leave() }
        }

        storage.child("users/\(uid)/avatar.jpg").delete(completion: nil)
        storage.child("users/\(uid)/banner.jpg").delete(completion: nil)
        group.enter()
        storage.child("users/\(uid)/rides").listAll { result, _ in
            result?.items.forEach { $0.delete(completion: nil) }
            group.leave()
        }

        group.notify(queue: .main) { [weak self] in
            user.delete { error in
                DispatchQueue.main.async {
                    if let error {
                        completion(self?.friendlyError(error) ?? error.localizedDescription)
                    } else {
                        completion(nil)
                    }
                }
            }
        }
    }

    private func friendlyError(_ error: Error) -> String {
        let code = (error as NSError).code
        switch AuthErrorCode(rawValue: code) {
        case .invalidEmail:
            return "That doesn't look like a valid email address."
        case .wrongPassword:
            return "Incorrect password. Try again or reset it."
        case .userNotFound:
            return "No account found with that email."
        case .emailAlreadyInUse:
            return "An account with that email already exists. Try logging in."
        case .weakPassword:
            return "Password must be at least 6 characters."
        case .networkError:
            return "Network error. Check your connection and try again."
        case .requiresRecentLogin:
            return "For security, please sign out and sign back in, then try again."
        default:
            return error.localizedDescription
        }
    }
}

// MARK: - Sign in with Apple callbacks
extension AuthManager: ASAuthorizationControllerDelegate, ASAuthorizationControllerPresentationContextProviding {
    func authorizationController(controller: ASAuthorizationController, didCompleteWithAuthorization authorization: ASAuthorization) {
        guard let appleIDCredential = authorization.credential as? ASAuthorizationAppleIDCredential,
              let nonce = appleNonce,
              let tokenData = appleIDCredential.identityToken,
              let idToken = String(data: tokenData, encoding: .utf8) else {
            setError("Apple didn't return a sign-in token. Please try again.")
            return
        }
        signIn(with: OAuthProvider.appleCredential(
            withIDToken: idToken,
            rawNonce: nonce,
            fullName: appleIDCredential.fullName
        ))
    }

    func authorizationController(controller: ASAuthorizationController, didCompleteWithError error: Error) {
        let authError = error as? ASAuthorizationError
        guard authError?.code != .canceled else { return }
        publish(error: error)
    }

    func presentationAnchor(for controller: ASAuthorizationController) -> ASPresentationAnchor {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first(where: { $0.isKeyWindow }) ?? ASPresentationAnchor()
    }
}

private extension UIViewController {
    var topMostViewController: UIViewController {
        if let presentedViewController { return presentedViewController.topMostViewController }
        if let navigationController = self as? UINavigationController,
           let visibleViewController = navigationController.visibleViewController {
            return visibleViewController.topMostViewController
        }
        if let tabController = self as? UITabBarController,
           let selectedViewController = tabController.selectedViewController {
            return selectedViewController.topMostViewController
        }
        return self
    }
}
