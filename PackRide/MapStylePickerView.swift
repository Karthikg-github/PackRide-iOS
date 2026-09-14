import SwiftUI
import MapKit

// MARK: - Reusable Map Style Picker (floating light toggle)
struct MapStylePickerView: View {
    @Binding var selectedIndex: Int
    private let options = [
        ("globe.americas.fill", "Satellite"),
        ("map.fill", "Standard"),
        ("car.fill", "Hybrid")
    ]

    var body: some View {
        HStack(spacing: 2) {
            ForEach(0..<3, id: \.self) { index in
                Button(action: {
                    withAnimation(.spring(response: 0.3)) { selectedIndex = index }
                }) {
                    VStack(spacing: 3) {
                        Image(systemName: options[index].0).font(.system(size: 13, weight: .semibold))
                        Text(options[index].1).font(.system(size: 8, weight: .bold)).tracking(0.3)
                    }
                    .foregroundColor(selectedIndex == index ? .prCoral : .prMuted)
                    .frame(width: 64, height: 44)
                    .background(selectedIndex == index ? Color.prCoralSoft : Color.clear)
                    .cornerRadius(10)
                }
            }
        }
        .padding(4)
        .background(Color.prCardBg)
        .cornerRadius(14)
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.prBorder, lineWidth: 1))
        .shadow(color: .black.opacity(0.08), radius: 8, y: 4)
    }
}

// MARK: - Helper to convert index to MapStyle (SwiftUI Maps)
extension MapStyle {
    static func fromIndex(_ index: Int) -> MapStyle {
        switch index {
        case 1: return .standard(elevation: .realistic)
        case 2: return .hybrid(elevation: .realistic, showsTraffic: true)
        default: return .imagery(elevation: .realistic)
        }
    }
}

// MARK: - Helper to apply to MKMapView (UIKit Maps)
extension MKMapView {
    func applyStyleIndex(_ index: Int) {
        switch index {
        case 1:
            self.mapType = .standard
            self.showsTraffic = false
        case 2:
            self.mapType = .hybrid
            self.showsTraffic = true
        default:
            self.mapType = .satellite
            self.showsTraffic = false
        }
    }
}
