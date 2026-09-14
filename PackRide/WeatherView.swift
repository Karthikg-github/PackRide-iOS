import SwiftUI
import CoreLocation

// MARK: - Weather Attribution (required by WeatherKit's Apple Weather &
// third-party attribution terms — see
// https://developer.apple.com/weatherkit/get-started/#attribution-requirements).
// Any screen displaying WeatherKit data must show, in reasonably close
// proximity to that data, the Apple Weather trademark ("Weather") plus a
// link to the data-source attribution page. This is a small tappable row
// combining both in one place — used at the bottom of every weather surface
// in the app (WeatherStrip, WeatherDetailCard).
struct WeatherAttributionView: View {
    var compact: Bool = false

    var body: some View {
        Link(destination: URL(string: "https://developer.apple.com/weatherkit/data-source-attribution/")!) {
            HStack(spacing: 3) {
                Image(systemName: "apple.logo").font(.system(size: compact ? 8 : 9))
                Text("Weather").font(.system(size: compact ? 9 : 10, weight: .semibold, design: .rounded))
            }
            .foregroundColor(.white.opacity(0.7))
        }
    }
}

// MARK: - Weather Strip (animated badge for hero section)
struct WeatherStrip: View {
    @StateObject private var weatherManager = WeatherManager()
    @ObservedObject private var locationManager = SharedLocationManager.shared
    @State private var errorMessage: String? = nil
    @State private var isAnimating: Bool = false

    private var isSunny: Bool {
        guard let w = weatherManager.currentWeather else { return false }
        let symbol = w.symbolName.lowercased()
        return symbol.contains("sun") || symbol.contains("clear")
    }

    private var isRainy: Bool {
        guard let w = weatherManager.currentWeather else { return false }
        let symbol = w.symbolName.lowercased()
        return symbol.contains("rain") || symbol.contains("drizzle") || symbol.contains("shower")
    }

    var body: some View {
        Group {
            if let w = weatherManager.currentWeather {
                // Aug 27, 2026 — two lines (temp, then location · condition
                // as a description line) instead of one long line, and the
                // safety dot/label ("Great Riding"/"Use Caution"/"Poor
                // Conditions") dropped per Karthik's request.
                HStack(spacing: 8) {
                    // Dynamic Weather Icon with continuous animations
                    Image(systemName: w.symbolName)
                        .font(.system(size: 16, weight: .bold))
                        .foregroundColor(weatherIconColor(w.symbolName))
                        .scaleEffect(isAnimating ? 1.15 : 1.0)
                        .rotationEffect(.degrees(isSunny && isAnimating ? 360 : 0))
                        .offset(y: isRainy && isAnimating ? 2 : -2)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(w.tempString)
                            .font(.system(size: 14, weight: .bold, design: .monospaced))
                            .foregroundColor(.white)

                        Text("\(w.locationName) · \(w.condition)")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundColor(.white.opacity(0.75))
                            .lineLimit(1)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Color.black.opacity(0.45))
                .cornerRadius(14)
                .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.white.opacity(0.18), lineWidth: 1))
                .onAppear {
                    startIconAnimation()
                }
            } else if weatherManager.isLoading {
                HStack(spacing: 8) {
                    ProgressView().tint(.white).scaleEffect(0.7)
                    Text("Loading weather...").font(.system(size: 11, weight: .medium)).foregroundColor(.white.opacity(0.8))
                }
                .padding(.horizontal, 12).padding(.vertical, 7)
                .background(Color.black.opacity(0.45))
                .cornerRadius(14)
                .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.white.opacity(0.18), lineWidth: 1))
            } else {
                Button(action: { fetchWeather() }) {
                    HStack(spacing: 6) {
                        Image(systemName: "cloud.sun.fill").font(.system(size: 13)).foregroundColor(.orange)
                        Text(errorMessage ?? "Tap for Weather")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(.white.opacity(0.8))
                        Image(systemName: "arrow.clockwise").font(.system(size: 10)).foregroundColor(.white.opacity(0.6))
                    }
                    .padding(.horizontal, 12).padding(.vertical, 7)
                    .background(Color.black.opacity(0.45))
                    .cornerRadius(14)
                    .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.white.opacity(0.18), lineWidth: 1))
                }
            }
        }
        .onAppear { fetchWeather() }
        .onChange(of: locationManager.location) { _, loc in
            if loc != nil {
                locationManager.stopUpdating(reason: "weather")
                if weatherManager.currentWeather == nil {
                    fetchWeather()
                }
            }
        }
    }

    private func startIconAnimation() {
        if isSunny {
            withAnimation(.linear(duration: 12).repeatForever(autoreverses: false)) {
                isAnimating = true
            }
        } else {
            withAnimation(.easeInOut(duration: 1.2).repeatForever(autoreverses: true)) {
                isAnimating = true
            }
        }
    }

    func fetchWeather() {
        guard let loc = locationManager.location else {
            locationManager.requestPermission()
            locationManager.startUpdating(reason: "weather")
            errorMessage = "Getting location..."
            return
        }
        errorMessage = nil
        Task {
            await weatherManager.fetchCurrentWeather(location: loc)
            if weatherManager.currentWeather == nil {
                await MainActor.run { errorMessage = Self.describeWeatherFailure(weatherManager.lastError) }
            }
        }
    }

    static func describeWeatherFailure(_ rawError: String?) -> String {
        guard let raw = rawError, !raw.isEmpty else {
            return "Weather unavailable — try again shortly"
        }
        let lower = raw.lowercased()
        let looksLikeActivationDelay = lower.contains("authenticat")
            || lower.contains("unauthorized")
            || lower.contains("403")
            || lower.contains("permission denied")
            || lower.contains("not entitled")
            || lower.contains("jwt")
        if looksLikeActivationDelay {
            return "WeatherKit delay (up to 24h)"
        }
        return "Weather error"
    }

    func safetyColor(_ w: RideWeatherInfo) -> Color {
        switch w.safetyColor {
        case "red": return .red
        case "yellow": return .orange
        default: return Color(red: 0.373, green: 0.851, blue: 0.541)
        }
    }

    func weatherIconColor(_ symbol: String) -> Color {
        let lower = symbol.lowercased()
        if lower.contains("sun") { return Color(red: 1.0, green: 0.75, blue: 0.2) }
        if lower.contains("rain") || lower.contains("drizzle") { return Color(red: 0.4, green: 0.7, blue: 1.0) }
        if lower.contains("cloud") { return Color.white.opacity(0.9) }
        if lower.contains("snow") { return .cyan }
        if lower.contains("wind") { return .teal }
        return .orange
    }
}

// MARK: - Weather Detail Card (for ride planning / waypoints)
struct WeatherDetailCard: View {
    let weather: RideWeatherInfo

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            // Location + condition
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(weather.locationName)
                        .font(.system(size: 15, weight: .bold, design: .rounded))
                        .foregroundColor(.prInk).lineLimit(1)
                    Text(weather.condition)
                        .font(.system(size: 13, design: .rounded))
                        .foregroundColor(.prMuted)
                }
                Spacer()
                HStack(spacing: 6) {
                    Image(systemName: weather.symbolName)
                        .font(.system(size: 28))
                        .foregroundStyle(iconGradient(weather.symbolName))
                    Text(weather.tempString)
                        .font(.system(size: 28, weight: .bold, design: .rounded))
                        .foregroundColor(.prInk)
                }
            }

            // Safety banner
            HStack(spacing: 8) {
                Circle().fill(safetyColor).frame(width: 8, height: 8)
                Text(weather.safetyLabel)
                    .font(.system(size: 12, weight: .bold, design: .rounded))
                    .foregroundColor(safetyColor)
                Spacer()
                Text("Feels like \(weather.feelsLikeString)")
                    .font(.system(size: 11, design: .rounded))
                    .foregroundColor(.prMuted)
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(safetyColor.opacity(0.08))
            .cornerRadius(10)
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(safetyColor.opacity(0.2), lineWidth: 1))

            // Stats grid
            HStack(spacing: 0) {
                WeatherStatItem(icon: "wind", label: "Wind", value: weather.windString)
                WeatherStatItem(icon: "drop.fill", label: "Rain", value: weather.precipString)
                WeatherStatItem(icon: "humidity.fill", label: "Humidity", value: weather.humidityString)
                WeatherStatItem(icon: "sun.max.fill", label: "UV", value: "\(weather.uvIndex)")
            }

            // Required WeatherKit attribution — see WeatherAttributionView.
            HStack {
                Spacer()
                WeatherAttributionView()
            }
        }
        .padding(16)
        .background(Color.prCardBg)
        .cornerRadius(16)
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.prBorder, lineWidth: 1))
    }

    var safetyColor: Color {
        switch weather.safetyColor {
        case "red": return .red
        case "yellow": return .orange
        default: return .green
        }
    }

    func iconGradient(_ symbol: String) -> LinearGradient {
        if symbol.contains("sun") { return LinearGradient(colors: [.orange, .yellow], startPoint: .top, endPoint: .bottom) }
        if symbol.contains("rain") { return LinearGradient(colors: [.blue, .cyan], startPoint: .top, endPoint: .bottom) }
        if symbol.contains("cloud") { return LinearGradient(colors: [.gray, .gray.opacity(0.5)], startPoint: .top, endPoint: .bottom) }
        return LinearGradient(colors: [.orange, .yellow], startPoint: .top, endPoint: .bottom)
    }
}

// MARK: - Weather Stat Item
struct WeatherStatItem: View {
    let icon: String
    let label: String
    let value: String
    var body: some View {
        VStack(spacing: 4) {
            Image(systemName: icon).font(.system(size: 14)).foregroundColor(.prCoral)
            Text(value).font(.system(size: 13, weight: .bold, design: .rounded)).foregroundColor(.prInk)
            Text(label).font(.system(size: 9, weight: .medium, design: .rounded)).foregroundColor(.prMuted)
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Hourly Forecast Strip
struct HourlyForecastStrip: View {
    let forecast: [HourlyRideForecast]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("NEXT 12 HOURS")
                .font(.system(size: 10, weight: .heavy, design: .rounded))
                .foregroundColor(.prMuted).tracking(1.5)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(forecast) { hour in
                        VStack(spacing: 6) {
                            Text(hour.hourString)
                                .font(.system(size: 10, weight: .medium, design: .rounded))
                                .foregroundColor(.prMuted)
                            Image(systemName: hour.symbolName)
                                .font(.system(size: 18))
                                .foregroundColor(hour.precipChance > 0.3 ? .blue : .orange)
                            Text("\(Int(hour.temperature))°")
                                .font(.system(size: 14, weight: .bold, design: .rounded))
                                .foregroundColor(.prInk)
                            if hour.precipChance > 0.1 {
                                Text("\(Int(hour.precipChance * 100))%")
                                    .font(.system(size: 9, weight: .semibold, design: .rounded))
                                    .foregroundColor(.blue)
                            }
                        }
                        .frame(width: 52)
                        .padding(.vertical, 8)
                        .background(hour.precipChance > 0.3 ? Color.blue.opacity(0.06) : Color.prCardBg)
                        .cornerRadius(12)
                        .overlay(RoundedRectangle(cornerRadius: 12).stroke(
                            hour.precipChance > 0.3 ? Color.blue.opacity(0.2) : Color.prBorder, lineWidth: 1))
                    }
                }
            }
        }
        .padding(16)
        .background(Color.prCardBg)
        .cornerRadius(16)
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.prBorder, lineWidth: 1))
    }
}

// MARK: - Route Weather View (weather at each waypoint)
struct RouteWeatherView: View {
    let waypoints: [(name: String, coordinate: CLLocationCoordinate2D)]
    @StateObject private var weatherManager = WeatherManager()
    @Environment(\.dismiss) var dismiss

    var body: some View {
        ZStack {
            Color.prBg.ignoresSafeArea()
            ScrollView {
                VStack(spacing: 0) {
                    PRWebPageHeader(
                        eyebrow: "Weather",
                        title: "Route Weather",
                        subtitle: "Conditions along your planned stops",
                        accent: .orange,
                        trailing: AnyView(
                            Button(action: { dismiss() }) {
                                Image(systemName: "xmark.circle.fill").font(.system(size: 22)).foregroundColor(.prMuted)
                            }
                        ),
                        showBackButton: false
                    )

                    VStack(spacing: 16) {
                    if weatherManager.isLoading {
                        VStack(spacing: 12) {
                            ProgressView().tint(.prCoral)
                            Text("Checking weather along your route...")
                                .font(.system(size: 13, design: .rounded)).foregroundColor(.prMuted)
                        }
                        .padding(.top, 40)
                    } else if weatherManager.waypointWeather.isEmpty {
                        VStack(spacing: 10) {
                            Image(systemName: "cloud.sun.fill").font(.system(size: 28)).foregroundColor(.orange)
                            Text(WeatherStrip.describeWeatherFailure(weatherManager.lastError))
                                .font(.system(size: 13, design: .rounded)).foregroundColor(.prMuted)
                                .multilineTextAlignment(.center).padding(.horizontal, 30)
                        }
                        .padding(.top, 40)
                    } else {
                        ForEach(weatherManager.waypointWeather) { weather in
                            WeatherDetailCard(weather: weather)
                                .padding(.horizontal, 16)
                        }
                    }

                    Spacer().frame(height: 40)
                    }
                    .padding(.top, 4)
                }
            }
        }
        .onAppear {
            Task { await weatherManager.fetchRouteWeather(waypoints: waypoints) }
        }
    }
}

// MARK: - Weather-Ahead (forecast at each stop's ESTIMATED ARRIVAL time)
struct RouteWeatherAheadView: View {
    let startCoordinate: CLLocationCoordinate2D?
    let stops: [(name: String, coordinate: CLLocationCoordinate2D)]
    @StateObject private var weatherManager = WeatherManager()
    @Environment(\.dismiss) var dismiss

    var body: some View {
        ZStack {
            Color.prBg.ignoresSafeArea()

            VStack(spacing: 0) {
                ScrollView {
                    VStack(spacing: 0) {
                        PRWebPageHeader(
                            eyebrow: "Weather",
                            title: "Weather Ahead",
                            subtitle: "Estimated conditions at each stop",
                            accent: .orange,
                            trailing: AnyView(
                                Button(action: { dismiss() }) {
                                    Image(systemName: "xmark.circle.fill").font(.system(size: 22)).foregroundColor(.prMuted)
                                }
                            ),
                            showBackButton: false
                        )

                        VStack(spacing: 16) {
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: "info.circle.fill").font(.system(size: 14)).foregroundColor(.prTeal)
                        Text("Arrival times are an estimate — straight-line distance between stops at an assumed \(MeasurementUnits.speedMph(WeatherManager.assumedAveragePaceMPH)) average pace, not real turn-by-turn routing. Actual arrival time and conditions may differ.")
                            .font(.system(size: 12)).foregroundColor(.prMuted).lineSpacing(2)
                    }
                    .padding(12)
                    .background(Color.prTeal.opacity(0.08))
                    .cornerRadius(12)
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.prTeal.opacity(0.2), lineWidth: 1))
                    .padding(.horizontal, 16)

                    if weatherManager.isLoadingRouteAhead {
                        VStack(spacing: 12) {
                            ProgressView().tint(.prCoral)
                            Text("Estimating arrival times and checking forecasts...")
                                .font(.system(size: 13, design: .rounded)).foregroundColor(.prMuted)
                        }
                        .padding(.top, 40)
                    } else if weatherManager.routeAheadForecasts.isEmpty {
                        VStack(spacing: 10) {
                            Image(systemName: "cloud.sun.fill").font(.system(size: 28)).foregroundColor(.orange)
                            Text(weatherManager.routeAheadError ?? WeatherStrip.describeWeatherFailure(weatherManager.lastError))
                                .font(.system(size: 13, design: .rounded)).foregroundColor(.prMuted)
                                .multilineTextAlignment(.center).padding(.horizontal, 30)
                        }
                        .padding(.top, 40)
                    } else {
                        ForEach(Array(weatherManager.routeAheadForecasts.enumerated()), id: \.element.id) { index, forecast in
                            RouteAheadForecastCard(forecast: forecast, stopNumber: index + 1)
                                .padding(.horizontal, 16)
                        }
                    }

                    Spacer().frame(height: 40)
                        }
                        .padding(.top, 4)
                    }
                }

                AdBannerFooter()
            }
        }
        .onAppear {
            Task { await weatherManager.fetchRouteAheadWeather(startCoordinate: startCoordinate, stops: stops) }
        }
    }
}

// MARK: - Route-Ahead Forecast Card
struct RouteAheadForecastCard: View {
    let forecast: RouteAheadForecast
    let stopNumber: Int

    var safetyColor: Color {
        switch forecast.safetyColor {
        case "red": return .red
        case "yellow": return .orange
        default: return .green
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                ZStack {
                    Circle().fill(Color.prCoralSoft).frame(width: 26, height: 26)
                    Text("\(stopNumber)").font(.system(size: 11, weight: .bold, design: .rounded)).foregroundColor(.prCoral)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(forecast.stopName)
                        .font(.system(size: 15, weight: .bold, design: .rounded))
                        .foregroundColor(.prInk).lineLimit(1)
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.turn.up.right").font(.system(size: 9)).foregroundColor(.prMuted)
                        Text("\(forecast.milesString) from start · ETA ~\(forecast.etaString)")
                            .font(.system(size: 11, design: .rounded)).foregroundColor(.prMuted)
                    }
                }
                Spacer()
                HStack(spacing: 6) {
                    Image(systemName: forecast.symbolName)
                        .font(.system(size: 24))
                        .foregroundStyle(.orange)
                    Text(forecast.tempString)
                        .font(.system(size: 24, weight: .bold, design: .rounded))
                        .foregroundColor(.prInk)
                }
            }

            HStack(spacing: 8) {
                Circle().fill(safetyColor).frame(width: 8, height: 8)
                Text(forecast.safetyLabel)
                    .font(.system(size: 12, weight: .bold, design: .rounded))
                    .foregroundColor(safetyColor)
                Spacer()
                Text(forecast.condition)
                    .font(.system(size: 11, design: .rounded))
                    .foregroundColor(.prMuted)
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(safetyColor.opacity(0.08))
            .cornerRadius(10)
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(safetyColor.opacity(0.2), lineWidth: 1))

            HStack(spacing: 0) {
                WeatherStatItem(icon: "wind", label: "Wind", value: forecast.windString)
                WeatherStatItem(icon: "drop.fill", label: "Rain", value: forecast.precipString)
            }

            HStack {
                Spacer()
                WeatherAttributionView()
            }
        }
        .padding(16)
        .background(Color.prCardBg)
        .cornerRadius(16)
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.prBorder, lineWidth: 1))
    }
}
