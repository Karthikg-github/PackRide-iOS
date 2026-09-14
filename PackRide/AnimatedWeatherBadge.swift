//
//  AnimatedWeatherBadge.swift
//  PackRide
//
//  Created by Karthik Gundavarapu on 8/26/26.
//

import SwiftUI

struct AnimatedWeatherBadge: View {
    let conditionText: String
    let temperatureText: String
    let locationName: String

    @State private var isAnimating = false

    var body: some View {
        HStack(spacing: 8) {
            // Weather icon with contextual animations
            ZStack {
                weatherIcon
                    .font(.system(size: 13, weight: .bold))
                    .foregroundColor(iconColor)
                    .scaleEffect(isAnimating ? 1.15 : 1.0)
                    .rotationEffect(.degrees(isSun ? (isAnimating ? 360 : 0) : 0))
                    .offset(y: isRain ? (isAnimating ? 2 : -2) : 0)
            }
            .frame(width: 18, height: 18)

            // Weather details
            HStack(spacing: 4) {
                Text(temperatureText)
                    .font(.system(size: 13, weight: .bold, design: .monospaced))
                    .foregroundColor(.white)
                
                Text("· \(locationName) · \(conditionText)")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.white.opacity(0.8))
                    .lineLimit(1)
            }

            // Riding condition indicator
            HStack(spacing: 4) {
                Circle()
                    .fill(Color(red: 0.373, green: 0.851, blue: 0.541))
                    .frame(width: 6, height: 6)
                    .scaleEffect(isAnimating ? 1.3 : 0.9)
                    .opacity(isAnimating ? 1.0 : 0.6)
                
                Text(ridingConditionText)
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(Color(red: 0.373, green: 0.851, blue: 0.541))
            }
            .padding(.leading, 4)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(
            ZStack {
                Color.black.opacity(0.45)
                // Subtle weather ambient glow
                ambientGlowColor.opacity(0.2)
            }
        )
        .cornerRadius(14)
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.white.opacity(0.18), lineWidth: 1))
        .onAppear {
            startWeatherAnimation()
        }
    }

    // MARK: - Weather Condition Logic

    private var isSun: Bool {
        conditionText.localizedCaseInsensitiveContains("sun") || conditionText.localizedCaseInsensitiveContains("clear")
    }

    private var isRain: Bool {
        conditionText.localizedCaseInsensitiveContains("rain") || conditionText.localizedCaseInsensitiveContains("drizzle") || conditionText.localizedCaseInsensitiveContains("shower")
    }

    private var isCloud: Bool {
        conditionText.localizedCaseInsensitiveContains("cloud") || conditionText.localizedCaseInsensitiveContains("overcast")
    }

    private var isThunder: Bool {
        conditionText.localizedCaseInsensitiveContains("thunder") || conditionText.localizedCaseInsensitiveContains("storm")
    }

    private var weatherIcon: Image {
        if isThunder { return Image(systemName: "cloud.bolt.rain.fill") }
        if isRain { return Image(systemName: "cloud.rain.fill") }
        if isCloud { return Image(systemName: "cloud.fill") }
        if isSun { return Image(systemName: "sun.max.fill") }
        return Image(systemName: "cloud.sun.fill")
    }

    private var iconColor: Color {
        if isSun { return Color(red: 1.0, green: 0.75, blue: 0.2) }
        if isRain || isThunder { return Color(red: 0.4, green: 0.7, blue: 1.0) }
        return Color.white.opacity(0.9)
    }

    private var ambientGlowColor: Color {
        if isSun { return Color.orange }
        if isThunder { return Color.purple }
        if isRain { return Color.blue }
        return Color.clear
    }

    private var ridingConditionText: String {
        if isThunder || isRain { return "Caution" }
        return "Great Riding"
    }

    // MARK: - Animation Triggers

    private func startWeatherAnimation() {
        if isSun {
            withAnimation(.linear(duration: 12).repeatForever(autoreverses: false)) {
                isAnimating = true
            }
        } else if isRain {
            withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) {
                isAnimating = true
            }
        } else {
            withAnimation(.easeInOut(duration: 1.5).repeatForever(autoreverses: true)) {
                isAnimating = true
            }
        }
    }
}
