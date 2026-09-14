import SwiftUI
import UIKit
import CoreImage.CIFilterBuiltins

// MARK: - App-native share cards
// Share a real image alongside the concise text/deep link. This makes the
// result look intentional in Messages, WhatsApp, and social apps without a
// hosted landing page or Open Graph metadata to maintain.
@MainActor
enum PackRideShareCard {
    static func shareGroupRide(code: String) {
        let joinURL = "packride://join?code=\(code)"
        share(
            GroupRideShareCard(code: code, qrPayload: joinURL),
            text: "Join my PackRide group ride. Code: \(code)\n\(joinURL)\n\nGet PackRide: https://apps.apple.com/app/id6772399785"
        )
    }

    static func shareCommunity(name: String, id: String, passcode: String, memberCount: Int) {
        let joinURL = "packride://joincommunity?id=\(id)&passcode=\(passcode)"
        share(
            CommunityShareCard(name: name, code: id, memberCount: memberCount, qrPayload: joinURL),
            text: "Join \(name) on PackRide.\nCommunity ID: \(id)\nPasscode: \(passcode)\n\(joinURL)\n\nGet PackRide: https://apps.apple.com/app/id6772399785"
        )
    }

    static func shareRideStats(_ ride: RideRecord) {
        share(
            RideStatsShareCard(ride: ride),
            text: "My PackRide \(ride.typeLabel.lowercased()): \(ride.distanceString) · \(ride.duration) · \(ride.maxSpeedString) top speed."
        )
    }

    static func shareRideStats(distance: Double, maxSpeed: Double, duration: String, maxLean: Double) {
        let ride = RideRecord(
            id: UUID().uuidString, date: Date(), distance: distance, maxSpeed: maxSpeed,
            duration: duration, rideCode: "", maxLeanAngle: maxLean
        )
        shareRideStats(ride)
    }

    private static func share<Card: View>(_ card: Card, text: String) {
        let renderer = ImageRenderer(content: card)
        renderer.scale = UIScreen.main.scale
        guard let image = renderer.uiImage else { return }

        let activity = UIActivityViewController(activityItems: [image, text], applicationActivities: nil)
        guard let scene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState == .foregroundActive }),
              let presenter = scene.windows.first(where: { $0.isKeyWindow })?.rootViewController else { return }
        presenter.present(activity, animated: true)
    }
}

private struct GroupRideShareCard: View {
    let code: String
    let qrPayload: String

    var body: some View {
        PackRideShareCardShell(eyebrow: "PACKRIDE · GROUP RIDE") {
            VStack(alignment: .leading, spacing: 14) {
                Text("The road is better together.")
                    .font(.system(size: 34, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .fixedSize(horizontal: false, vertical: true)
                Text("SCAN TO JOIN THE PACK")
                    .font(.system(size: 11, weight: .heavy))
                    .tracking(2)
                    .foregroundStyle(Color.white.opacity(0.7))
            }
        } footer: {
            HStack(alignment: .center, spacing: 20) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("RIDE CODE")
                        .shareLabel()
                    Text(code)
                        .font(.system(size: 38, weight: .heavy, design: .monospaced))
                        .tracking(3)
                        .foregroundStyle(.white)
                }
                Spacer()
                ShareQRCode(payload: qrPayload)
            }
        }
    }
}

private struct CommunityShareCard: View {
    let name: String
    let code: String
    let memberCount: Int
    let qrPayload: String

    var body: some View {
        PackRideShareCardShell(eyebrow: "PACKRIDE · RIDING COMMUNITY") {
            VStack(alignment: .leading, spacing: 12) {
                Text(name)
                    .font(.system(size: 36, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .lineLimit(2)
                Text("\(memberCount) member\(memberCount == 1 ? "" : "s") · private riding crew")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(Color.white.opacity(0.78))
            }
        } footer: {
            HStack(spacing: 20) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("COMMUNITY CODE")
                        .shareLabel()
                    Text(code)
                        .font(.system(size: 34, weight: .heavy, design: .monospaced))
                        .tracking(2)
                        .foregroundStyle(.white)
                    Text("Ask the sender for the passcode")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Color.white.opacity(0.65))
                }
                Spacer()
                ShareQRCode(payload: qrPayload)
            }
        }
    }
}

private struct RideStatsShareCard: View {
    let ride: RideRecord

    var body: some View {
        PackRideShareCardShell(eyebrow: "PACKRIDE · \(ride.typeLabel.uppercased())") {
            VStack(alignment: .leading, spacing: 10) {
                Text("Ride complete")
                    .font(.system(size: 36, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                Text(ride.formattedDate)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(Color.white.opacity(0.72))
            }
        } footer: {
            HStack(spacing: 0) {
                ShareMetric(value: ride.distanceString, label: "DISTANCE")
                ShareMetric(value: ride.duration, label: "TIME")
                ShareMetric(value: ride.maxSpeedString, label: "TOP SPEED")
                if ride.maxLeanAngle > 0 {
                    ShareMetric(value: String(format: "%.0f°", ride.maxLeanAngle), label: "MAX LEAN")
                }
            }
        }
    }
}

private struct PackRideShareCardShell<Content: View, Footer: View>: View {
    let eyebrow: String
    @ViewBuilder let content: Content
    @ViewBuilder let footer: Footer

    init(eyebrow: String, @ViewBuilder content: () -> Content, @ViewBuilder footer: () -> Footer) {
        self.eyebrow = eyebrow
        self.content = content()
        self.footer = footer()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 22) {
                HStack(spacing: 10) {
                    Image(systemName: "arrowtriangle.up.fill")
                        .font(.system(size: 16, weight: .heavy))
                        .foregroundStyle(.white)
                        .frame(width: 34, height: 34)
                        .background(Color.prCoral)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                    Text(eyebrow)
                        .font(.system(size: 11, weight: .heavy))
                        .tracking(1.8)
                        .foregroundStyle(Color.white.opacity(0.78))
                }
                content
                Spacer(minLength: 0)
            }
            .padding(28)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: 260)
            .background(
                LinearGradient(
                    colors: [Color(red: 0.10, green: 0.12, blue: 0.16), Color(red: 0.24, green: 0.12, blue: 0.05)],
                    startPoint: .topLeading, endPoint: .bottomTrailing
                )
            )

            footer
                .padding(24)
                .frame(maxWidth: .infinity, minHeight: 130, alignment: .leading)
                .background(Color(red: 0.055, green: 0.055, blue: 0.065))
        }
        .frame(width: 720, height: 390)
        .clipShape(RoundedRectangle(cornerRadius: 28))
    }
}

private struct ShareMetric: View {
    let value: String
    let label: String

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(value)
                .font(.system(size: 22, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.65)
            Text(label)
                .shareLabel()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct ShareQRCode: View {
    let payload: String

    var body: some View {
        Group {
            if let image = qrImage {
                Image(uiImage: image)
                    .interpolation(.none)
                    .resizable()
                    .scaledToFit()
            } else {
                Color.white
            }
        }
        .padding(8)
        .frame(width: 94, height: 94)
        .background(.white)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private var qrImage: UIImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = payload.data(using: .utf8) ?? Data()
        filter.correctionLevel = "M"
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 6, y: 6)),
              let cgImage = CIContext().createCGImage(output, from: output.extent) else { return nil }
        return UIImage(cgImage: cgImage)
    }
}

private extension View {
    func shareLabel() -> some View {
        font(.system(size: 10, weight: .heavy))
            .tracking(1.5)
            .foregroundStyle(Color.white.opacity(0.58))
    }
}
