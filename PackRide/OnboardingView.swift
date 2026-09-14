import SwiftUI

struct OnboardingView: View {
    @AppStorage("hasCompletedOnboarding") var hasCompletedOnboarding = false
    @AppStorage("riderName") var riderName = ""
    @AppStorage("riderBike") var riderBike = ""
    @AppStorage("riderCity") var riderCity = ""
    @AppStorage("riderExperience") var riderExperience = "Intermediate"

    @State private var currentPage = 0
    @State private var tempName = ""
    @State private var tempBike = ""
    @State private var tempCity = ""
    @State private var selectedExperience = "Intermediate"

    let experienceLevels = ["Beginner", "Intermediate", "Advanced", "Expert"]

    var body: some View {
        ZStack {
            Color.prBg.ignoresSafeArea()

            VStack {
                HStack(spacing: 8) {
                    ForEach(0..<4) { index in
                        RoundedRectangle(cornerRadius: 4)
                            .fill(currentPage == index ? Color.prCoral : Color.prBorder)
                            .frame(width: currentPage == index ? 24 : 8, height: 8)
                            .animation(.spring(), value: currentPage)
                    }
                }
                .padding(.top, 60)

                Spacer()

                if currentPage == 0 {
                    WelcomePage()
                } else if currentPage == 1 {
                    NamePage(tempName: $tempName)
                } else if currentPage == 2 {
                    BikePage(tempBike: $tempBike, tempCity: $tempCity,
                            selectedExperience: $selectedExperience,
                            experienceLevels: experienceLevels)
                } else if currentPage == 3 {
                    ReadyPage(name: tempName)
                }

                Spacer()

                Button(action: {
                    handleNext()
                }) {
                    Text(currentPage == 3 ? "Start Riding" : "Continue")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 17)
                        .background(Color.prCoral)
                        .cornerRadius(15)
                        .padding(.horizontal, 24)
                }
                .disabled(currentPage == 1 && tempName.isEmpty)
                .opacity(currentPage == 1 && tempName.isEmpty ? 0.5 : 1)

                if currentPage > 0 {
                    Button(action: {
                        withAnimation {
                            currentPage -= 1
                        }
                    }) {
                        Text("Back")
                            .font(.system(size: 14))
                            .foregroundColor(.prMuted)
                    }
                    .padding(.top, 8)
                }

                Spacer().frame(height: 40)
            }
        }
    }

    func handleNext() {
        if currentPage < 3 {
            withAnimation(.spring()) {
                currentPage += 1
            }
        } else {
            riderName = tempName
            riderBike = tempBike
            riderCity = tempCity
            riderExperience = selectedExperience
            hasCompletedOnboarding = true
        }
    }
}

// MARK: - Welcome Page
struct WelcomePage: View {
    var body: some View {
        VStack(spacing: 20) {
            ZStack {
                RoundedRectangle(cornerRadius: 24)
                    .fill(Color.prCoralSoft)
                    .frame(width: 88, height: 88)
                Image(systemName: "arrowtriangle.up.fill")
                    .font(.system(size: 32))
                    .foregroundColor(.prCoral)
            }

            VStack(spacing: 8) {
                Text("Welcome to\nPackRide")
                    .font(.system(size: 26, weight: .bold))
                    .foregroundColor(.prInk)
                    .multilineTextAlignment(.center)
                Text("The riding companion built for finding great roads, riding with your pack, and staying safe out there.")
                    .font(.system(size: 14))
                    .foregroundColor(.prMuted)
                    .multilineTextAlignment(.center)
                    .lineSpacing(3)
                    .padding(.horizontal, 12)
            }

            VStack(alignment: .leading, spacing: 12) {
                FeatureRow(color: .prCoral, text: "Curvy-road route planning")
                FeatureRow(color: .prTeal, text: "Automatic crash detection")
                FeatureRow(color: .prCoral, text: "Live pack tracking on group rides")
            }
            .padding(18)
            .background(Color.prCardBg)
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.prBorder, lineWidth: 1))
            .cornerRadius(16)
            .padding(.horizontal, 24)
        }
    }
}

// MARK: - Name Page
struct NamePage: View {
    @Binding var tempName: String

    var body: some View {
        VStack(spacing: 28) {
            ZStack {
                Circle()
                    .fill(Color.prCoral)
                    .frame(width: 80, height: 80)
                Text(tempName.isEmpty ? "?" : tempName.rideInitials)
                    .font(.system(size: 26, weight: .bold))
                    .foregroundColor(.white)
            }

            VStack(spacing: 8) {
                Text("What's your name?")
                    .font(.system(size: 24, weight: .bold))
                    .foregroundColor(.prInk)
                Text("This is how other riders will\nsee you on the map.")
                    .font(.system(size: 14))
                    .foregroundColor(.prMuted)
                    .multilineTextAlignment(.center)
            }

            TextField("", text: $tempName, prompt: Text("Your first name").foregroundColor(.prMuted))
                .font(.system(size: 18))
                .foregroundColor(.prInk)
                .multilineTextAlignment(.center)
                .padding(16)
                .background(Color.prCardBg)
                .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.prBorder, lineWidth: 1))
                .cornerRadius(14)
                .padding(.horizontal, 24)
        }
    }
}

// MARK: - Bike Page
struct BikePage: View {
    @Binding var tempBike: String
    @Binding var tempCity: String
    @Binding var selectedExperience: String
    let experienceLevels: [String]

    var body: some View {
        VStack(spacing: 22) {
            VStack(spacing: 10) {
                Image(systemName: "arrowtriangle.up.fill")
                    .font(.system(size: 36))
                    .foregroundColor(.prCoral)
                Text("Tell us about\nyour ride")
                    .font(.system(size: 24, weight: .bold))
                    .foregroundColor(.prInk)
                    .multilineTextAlignment(.center)
            }

            VStack(spacing: 12) {
                TextField("", text: $tempBike, prompt: Text("Your bike (e.g. Yamaha R1)").foregroundColor(.prMuted))
                    .font(.system(size: 14))
                    .foregroundColor(.prInk)
                    .padding(15)
                    .background(Color.prCardBg)
                    .overlay(RoundedRectangle(cornerRadius: 13).stroke(Color.prBorder, lineWidth: 1))
                    .cornerRadius(13)

                TextField("", text: $tempCity, prompt: Text("Your city").foregroundColor(.prMuted))
                    .font(.system(size: 14))
                    .foregroundColor(.prInk)
                    .padding(15)
                    .background(Color.prCardBg)
                    .overlay(RoundedRectangle(cornerRadius: 13).stroke(Color.prBorder, lineWidth: 1))
                    .cornerRadius(13)
            }
            .padding(.horizontal, 24)

            VStack(alignment: .leading, spacing: 12) {
                Text("Experience Level")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.prMuted)
                    .padding(.horizontal, 24)

                HStack(spacing: 8) {
                    ForEach(experienceLevels, id: \.self) { level in
                        Button(action: {
                            selectedExperience = level
                        }) {
                            Text(level)
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundColor(selectedExperience == level ? .white : .prMuted)
                                .padding(.horizontal, 14)
                                .padding(.vertical, 9)
                                .background(selectedExperience == level ? Color.prCoral : Color.prCardBg)
                                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.prBorder, lineWidth: selectedExperience == level ? 0 : 1))
                                .cornerRadius(10)
                        }
                    }
                }
                .padding(.horizontal, 24)
            }
        }
    }
}

// MARK: - Ready Page
struct ReadyPage: View {
    let name: String

    var body: some View {
        VStack(spacing: 20) {
            ZStack {
                RoundedRectangle(cornerRadius: 24)
                    .fill(Color.prCoralSoft)
                    .frame(width: 88, height: 88)
                Image(systemName: "checkmark")
                    .font(.system(size: 36, weight: .bold))
                    .foregroundColor(.prCoral)
            }

            VStack(spacing: 8) {
                Text("You're all set, \(name)")
                    .font(.system(size: 26, weight: .bold))
                    .foregroundColor(.prInk)
                    .multilineTextAlignment(.center)
                Text("Your PackRide profile is ready.\nTime to hit the road!")
                    .font(.system(size: 14))
                    .foregroundColor(.prMuted)
                    .multilineTextAlignment(.center)
                    .lineSpacing(3)
            }

            VStack(alignment: .leading, spacing: 14) {
                TipRow(number: "1", text: "Create or join a group ride")
                TipRow(number: "2", text: "Share your ride code with friends")
                TipRow(number: "3", text: "Ride together, stay connected!")
            }
            .padding(18)
            .background(Color.prCardBg)
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.prBorder, lineWidth: 1))
            .cornerRadius(16)
            .padding(.horizontal, 24)
        }
    }
}

// MARK: - Feature Row
struct FeatureRow: View {
    let color: Color
    let text: String

    var body: some View {
        HStack(spacing: 10) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(text)
                .font(.system(size: 13))
                .foregroundColor(.prInk)
        }
    }
}

// MARK: - Tip Row
struct TipRow: View {
    let number: String
    let text: String

    var body: some View {
        HStack(spacing: 14) {
            ZStack {
                Circle().fill(Color.prCoralSoft).frame(width: 22, height: 22)
                Text(number)
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(.prCoral)
            }
            Text(text)
                .font(.system(size: 13))
                .foregroundColor(.prInk)
        }
    }
}

#Preview {
    OnboardingView()
}
