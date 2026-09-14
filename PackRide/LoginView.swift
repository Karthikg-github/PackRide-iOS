import SwiftUI

// PackRide brand colors
// Aug 2026: these were flat, fixed colors — fine back when the whole app was
// pinned to light mode (see PackRideApp.swift's old `.preferredColorScheme(.light)`).
// Now that there's a Dark Mode toggle in Profile, each token below is built from
// `UIColor(dynamicProvider:)`, which returns a different color depending on
// whether the *current* trait collection is light or dark. That trait collection
// is exactly what `.preferredColorScheme()` sets at the app root — so as soon as
// the toggle flips it, every view using these tokens re-colors itself
// automatically, with no per-screen "if darkMode" checks needed anywhere else.
private func adaptive(light: (Double, Double, Double), dark: (Double, Double, Double)) -> Color {
    Color(UIColor { trait in
        trait.userInterfaceStyle == .dark
            ? UIColor(red: dark.0, green: dark.1, blue: dark.2, alpha: 1)
            : UIColor(red: light.0, green: light.1, blue: light.2, alpha: 1)
    })
}

extension Color {
    // REVER-inspired PackRide tokens — white canvas, ink type, orange accent,
    // charcoal chrome. Adaptive so Dark Mode in Profile still works.
    static let prBg = adaptive(light: (0.973, 0.973, 0.973), dark: (0.071, 0.071, 0.075))       // #F8F8F8 / #121213
    static let prCoral = Color(red: 1.0, green: 0.416, blue: 0.0)   // #FF6A00 — REVER orange
    static let prCoralSoft = adaptive(light: (1.0, 0.925, 0.863), dark: (0.28, 0.14, 0.04)) // soft orange wash
    static let prTealSoft = adaptive(light: (0.906, 0.937, 0.945), dark: (0.06, 0.17, 0.20))
    static let prRouteSoft = adaptive(light: (0.941, 0.925, 0.898), dark: (0.22, 0.17, 0.10))
    static let prInk = adaptive(light: (0.102, 0.102, 0.110), dark: (0.96, 0.96, 0.96))     // #1A1A1C
    static let prMuted = adaptive(light: (0.45, 0.45, 0.47), dark: (0.62, 0.62, 0.64))
    static let prBorder = adaptive(light: (0.90, 0.90, 0.91), dark: (0.22, 0.22, 0.24))
    static let prTeal = Color(red: 0.169, green: 0.431, blue: 0.522)
    static let prCardBg = adaptive(light: (1.0, 1.0, 1.0), dark: (0.12, 0.12, 0.13))
    static let prFieldBg = adaptive(light: (0.965, 0.965, 0.968), dark: (0.16, 0.16, 0.17))
    static let prInkFixed = Color(red: 0.102, green: 0.102, blue: 0.110)
    static let prTabBar = Color(red: 0.090, green: 0.090, blue: 0.098) // always-dark REVER tab bar
    static let prCover = Color(red: 0.145, green: 0.165, blue: 0.188)
}

struct LoginView: View {
    @EnvironmentObject var auth: AuthManager

    @State private var isLogin = true
    @State private var email = ""
    @State private var password = ""
    @State private var confirmPassword = ""
    @State private var showForgotPassword = false
    @State private var resetEmail = ""
    @State private var resetSent = false
    @State private var isLoading = false

    var body: some View {
        ZStack {
            Color.prBg.ignoresSafeArea()

            ScrollView {
                VStack(spacing: 0) {

                    loginHero

                    // Login / Sign Up Toggle
                    HStack(spacing: 0) {
                        Button(action: { withAnimation { isLogin = true } }) {
                            Text("Log In")
                                .font(.system(size: 14, weight: .bold))
                                .foregroundColor(isLogin ? .prInk : .prMuted)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 11)
                                .background(isLogin ? Color.prCardBg : Color.clear)
                                .cornerRadius(11)
                        }
                        Button(action: { withAnimation { isLogin = false } }) {
                            Text("Sign Up")
                                .font(.system(size: 14, weight: .bold))
                                .foregroundColor(!isLogin ? .prInk : .prMuted)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 11)
                                .background(!isLogin ? Color.prCardBg : Color.clear)
                                .cornerRadius(11)
                        }
                    }
                    .padding(4)
                    .background(Color(red: 0.941, green: 0.925, blue: 0.898)) // #F0ECE5
                    .cornerRadius(14)
                    .padding(.horizontal, 24)
                    .padding(.top, 24)
                    .padding(.bottom, 24)

                    VStack(spacing: 10) {
                        SocialSignInButton(title: "Continue with Apple", icon: "apple", foreground: .prInk, background: .prCardBg) {
                            auth.signInWithApple()
                        }
                        SocialSignInButton(title: "Continue with Google", icon: "g.circle.fill", foreground: .prInk, background: .prCardBg) {
                            auth.signInWithGoogle()
                        }
                        SocialSignInButton(title: "Continue with Facebook", icon: "f.circle.fill", foreground: .white, background: Color(red: 0.09, green: 0.32, blue: 0.61)) {
                            auth.signInWithFacebook()
                        }
                    }
                    .padding(.horizontal, 24)

                    HStack(spacing: 10) {
                        Rectangle().fill(Color.prBorder).frame(height: 1)
                        Text("OR USE EMAIL")
                            .font(.system(size: 10, weight: .heavy))
                            .tracking(1.4)
                            .foregroundColor(.prMuted)
                        Rectangle().fill(Color.prBorder).frame(height: 1)
                    }
                    .padding(.horizontal, 24)
                    .padding(.vertical, 22)

                    // Form Fields
                    VStack(spacing: 12) {
                        TextField("", text: $email, prompt: Text("Email address").foregroundColor(.prMuted))
                            .foregroundColor(.prInk)
                            .keyboardType(.emailAddress)
                            .autocapitalization(.none)
                            .autocorrectionDisabled()
                            .padding(15)
                            .background(Color.prCardBg)
                            .overlay(RoundedRectangle(cornerRadius: 13).stroke(Color.prBorder, lineWidth: 1))
                            .cornerRadius(13)

                        SecureField("Password", text: $password)
                            .foregroundColor(.prInk)
                            .padding(15)
                            .background(Color.prCardBg)
                            .overlay(RoundedRectangle(cornerRadius: 13).stroke(Color.prBorder, lineWidth: 1))
                            .cornerRadius(13)

                        if !isLogin {
                            SecureField("Confirm password", text: $confirmPassword)
                                .foregroundColor(.prInk)
                                .padding(15)
                                .background(Color.prCardBg)
                                .overlay(RoundedRectangle(cornerRadius: 13).stroke(Color.prBorder, lineWidth: 1))
                                .cornerRadius(13)
                                .transition(.opacity.combined(with: .move(edge: .top)))
                        }
                    }
                    .padding(.horizontal, 24)

                    if isLogin {
                        HStack {
                            Spacer()
                            Button(action: { showForgotPassword = true }) {
                                Text("Forgot Password?")
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundColor(.prCoral)
                            }
                        }
                        .padding(.horizontal, 24)
                        .padding(.top, 10)
                    }

                    if !auth.errorMessage.isEmpty {
                        HStack(spacing: 8) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundColor(Color(red: 0.827, green: 0.231, blue: 0.173)) // #D33B2C
                                .font(.system(size: 14))
                            Text(auth.errorMessage)
                                .font(.system(size: 13))
                                .foregroundColor(Color(red: 0.827, green: 0.231, blue: 0.173))
                                .multilineTextAlignment(.leading)
                            Spacer()
                        }
                        .padding(12)
                        .background(Color(red: 0.988, green: 0.922, blue: 0.906)) // #FCEBE7
                        .cornerRadius(10)
                        .padding(.horizontal, 24)
                        .padding(.top, 14)
                    }

                    Button(action: handleSubmit) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 14)
                                .fill(isFormValid ? Color.prCoral : Color.prCoral.opacity(0.4))
                            if isLoading {
                                ProgressView().tint(.white)
                            } else {
                                Text(isLogin ? "Log In" : "Create Account")
                                    .font(.system(size: 16, weight: .bold))
                                    .foregroundColor(.white)
                            }
                        }
                        .frame(height: 54)
                    }
                    .disabled(!isFormValid || isLoading)
                    .padding(.horizontal, 24)
                    .padding(.top, 22)

                    HStack(spacing: 4) {
                        Text(isLogin ? "Don't have an account?" : "Already have an account?")
                            .font(.system(size: 13))
                            .foregroundColor(.prMuted)
                        Button(action: { withAnimation { isLogin.toggle() } }) {
                            Text(isLogin ? "Sign Up" : "Log In")
                                .font(.system(size: 13, weight: .bold))
                                .foregroundColor(.prCoral)
                        }
                    }
                    .padding(.top, 20)
                    .padding(.bottom, 40)
                }
            }
        }
        .sheet(isPresented: $showForgotPassword) {
            ForgotPasswordSheet(
                resetEmail: $resetEmail,
                resetSent: $resetSent,
                onSend: { email in
                    auth.resetPassword(email: email) { success in
                        resetSent = success
                    }
                },
                onDismiss: {
                    showForgotPassword = false
                    resetEmail = ""
                    resetSent = false
                }
            )
        }
    }

    // MARK: - Full-Bleed Hero
    private var loginHero: some View {
        ZStack(alignment: .bottomLeading) {
            Color.prCover

            Image(systemName: "arrowtriangle.up.fill")
                .font(.system(size: 160))
                .foregroundColor(.white.opacity(0.05))
                .rotationEffect(.degrees(-12))
                .offset(x: 90, y: -10)

            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    RoundedRectangle(cornerRadius: 14)
                        .fill(Color.prCoral)
                        .frame(width: 44, height: 44)
                        .overlay(
                            Image(systemName: "arrowtriangle.up.fill")
                                .font(.system(size: 18))
                                .foregroundColor(.white)
                        )
                    Text("PACKRIDE")
                        .font(.system(size: 14, weight: .heavy))
                        .tracking(2.6)
                        .foregroundColor(.white)
                }
                Text("Ride together.\nStay connected.")
                    .font(.system(size: 28, weight: .bold, design: .rounded))
                    .foregroundColor(.white)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(20)
            .padding(.bottom, 4)
        }
        .frame(height: 210)
        .clipped()
    }

    var isFormValid: Bool {
        if isLogin {
            return !email.isEmpty && !password.isEmpty
        } else {
            return !email.isEmpty && password.count >= 6 && password == confirmPassword
        }
    }

    func handleSubmit() {
        isLoading = true
        if isLogin {
            auth.login(email: email, password: password)
        } else {
            auth.register(email: email, password: password)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            isLoading = false
        }
    }
}

private struct SocialSignInButton: View {
    let title: String
    let icon: String
    let foreground: Color
    let background: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 18, weight: .semibold))
                    .frame(width: 22)
                Text(title)
                    .font(.system(size: 15, weight: .bold))
                Spacer()
            }
            .foregroundColor(foreground)
            .padding(.horizontal, 16)
            .frame(height: 52)
            .background(background)
            .overlay(RoundedRectangle(cornerRadius: 13).stroke(Color.prBorder, lineWidth: 1))
            .clipShape(RoundedRectangle(cornerRadius: 13))
        }
    }
}

// MARK: - Forgot Password Sheet
struct ForgotPasswordSheet: View {
    @Binding var resetEmail: String
    @Binding var resetSent: Bool
    let onSend: (String) -> Void
    let onDismiss: () -> Void

    @State private var spamFlash = false

    var body: some View {
        ZStack {
            Color.prBg.ignoresSafeArea()

            VStack(spacing: 28) {
                RoundedRectangle(cornerRadius: 3)
                    .fill(Color.prBorder)
                    .frame(width: 40, height: 5)
                    .padding(.top, 12)

                if resetSent {
                    VStack(spacing: 20) {
                        ZStack {
                            Circle()
                                .fill(Color(red: 0.891, green: 0.965, blue: 0.918)) // #E3F6EA
                                .frame(width: 90, height: 90)
                            Image(systemName: "checkmark.circle.fill")
                                .font(.system(size: 44))
                                .foregroundColor(Color(red: 0.180, green: 0.620, blue: 0.357)) // #2E9E5B
                        }
                        Text("Email Sent!")
                            .font(.system(size: 22, weight: .bold))
                            .foregroundColor(.prInk)
                        Text("Check your inbox for a password reset link. It may take a minute or two to arrive.")
                            .font(.system(size: 14))
                            .foregroundColor(.prMuted)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 24)
                        HStack(spacing: 8) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundColor(Color(red: 0.612, green: 0.431, blue: 0.055)) // #9C6E0E
                                .font(.system(size: 13))
                            Text("Can't find it? Check your spam or junk folder.")
                                .font(.system(size: 13))
                                .foregroundColor(Color(red: 0.612, green: 0.431, blue: 0.055))
                        }
                        .padding(12)
                        .background(spamFlash ? Color(red: 0.984, green: 0.937, blue: 0.796) : Color(red: 0.984, green: 0.953, blue: 0.871)) // #FBF3DE tones
                        .cornerRadius(10)
                        .padding(.horizontal, 24)
                        .scaleEffect(spamFlash ? 1.04 : 1.0)
                        .onAppear {
                            withAnimation(.easeInOut(duration: 0.6).repeatForever(autoreverses: true)) {
                                spamFlash = true
                            }
                        }
                        Button(action: onDismiss) {
                            Text("Done")
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundColor(.white)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 16)
                                .background(Color.prCoral)
                                .cornerRadius(14)
                        }
                        .padding(.horizontal, 24)
                    }
                } else {
                    VStack(spacing: 16) {
                        ZStack {
                            Circle()
                                .fill(Color.prCoralSoft)
                                .frame(width: 90, height: 90)
                            Image(systemName: "lock.rotation")
                                .font(.system(size: 40))
                                .foregroundColor(.prCoral)
                        }
                        Text("Reset Password")
                            .font(.system(size: 22, weight: .bold))
                            .foregroundColor(.prInk)
                        Text("Enter your email and we'll send you a link to reset your password.")
                            .font(.system(size: 14))
                            .foregroundColor(.prMuted)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 24)

                        TextField("", text: $resetEmail, prompt: Text("Your email address").foregroundColor(.prMuted))
                            .foregroundColor(.prInk)
                            .keyboardType(.emailAddress)
                            .autocapitalization(.none)
                            .autocorrectionDisabled()
                            .padding(15)
                            .background(Color.prCardBg)
                            .overlay(RoundedRectangle(cornerRadius: 13).stroke(Color.prBorder, lineWidth: 1))
                            .cornerRadius(13)
                            .padding(.horizontal, 24)

                        Button(action: { onSend(resetEmail) }) {
                            Text("Send Reset Email")
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundColor(.white)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 16)
                                .background(resetEmail.isEmpty ? Color.prCoral.opacity(0.4) : Color.prCoral)
                                .cornerRadius(14)
                        }
                        .disabled(resetEmail.isEmpty)
                        .padding(.horizontal, 24)

                        Button(action: onDismiss) {
                            Text("Cancel")
                                .font(.system(size: 14))
                                .foregroundColor(.prMuted)
                        }
                    }
                }

                Spacer()
            }
        }
    }
}
