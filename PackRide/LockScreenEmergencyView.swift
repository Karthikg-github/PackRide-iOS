//
//  LockScreenEmergencyView.swift
//  PackRide
//
//  Created by Karthik Gundavarapu on 8/25/26.
//

import SwiftUI

public struct LockScreenEmergencyView: View {
    @AppStorage("riderName") private var riderName = ""
    @AppStorage("bloodType") private var bloodType = ""
    @AppStorage("allergies") private var allergies = ""
    @State private var emergencyContacts: [EmergencyContact] = []

    public var crashTimestamp: Date
    @Environment(\.dismiss) private var dismiss

    public init(crashTimestamp: Date = Date()) {
        self.crashTimestamp = crashTimestamp
    }

    public var body: some View {
        ZStack {
            // High contrast solid background
            Color.black.ignoresSafeArea()

            VStack(spacing: 20) {
                // Flashy Warning Header
                HStack {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 36, weight: .bold))
                        .foregroundColor(.yellow)
                    Text("CRASH DETECTED")
                        .font(.system(size: 28, weight: .black))
                        .foregroundColor(.white)
                }
                .padding()
                .frame(maxWidth: .infinity)
                .background(Color.red)
                .cornerRadius(12)

                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        
                        // 1. Time of Impact
                        EmergencyDataRow(
                            label: "TIME OF IMPACT",
                            value: formattedTimestamp(crashTimestamp),
                            accentColor: .yellow
                        )

                        Divider().background(Color.white)

                        // 2. Name
                        EmergencyDataRow(
                            label: "NAME",
                            value: riderName.isEmpty ? "Unknown" : riderName,
                            accentColor: .white
                        )

                        Divider().background(Color.white)

                        // 3. Blood Type
                        EmergencyDataRow(
                            label: "BLOOD TYPE",
                            value: bloodType.isEmpty ? "UNKNOWN" : bloodType,
                            accentColor: .red
                        )

                        Divider().background(Color.white)

                        // 4. Severe Allergies & Medical Conditions
                        EmergencyDataRow(
                            label: "CONDITIONS & ALLERGIES",
                            value: buildMedicalSummary(),
                            accentColor: .yellow
                        )

                        Divider().background(Color.white)

                        // 5. Emergency Contact
                        EmergencyDataRow(
                            label: "EMERGENCY CONTACT",
                            value: emergencyContactSummary(),
                            accentColor: .green
                        )
                    }
                    .padding()
                }

                Spacer()

                Button(action: { dismiss() }) {
                    Text("DISMISS SCREEN")
                        .font(.system(size: 20, weight: .bold))
                        .foregroundColor(.black)
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(Color.white)
                        .cornerRadius(10)
                }
            }
            .padding()
        }
        .onAppear(perform: loadEmergencyContacts)
    }

    private func formattedTimestamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss 'EDT' (yyyy-MM-dd)"
        return formatter.string(from: date)
    }

    private func buildMedicalSummary() -> String {
        allergies.isEmpty ? "None Reported" : "Allergies: \(allergies)"
    }

    private func emergencyContactSummary() -> String {
        guard !emergencyContacts.isEmpty else { return "None Listed" }

        return emergencyContacts
            .map { contact in
                [contact.name, contact.phone]
                    .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                    .joined(separator: "\n")
            }
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
    }

    private func loadEmergencyContacts() {
        guard let data = UserDefaults.standard.data(forKey: "emergencyContacts"),
              let decoded = try? JSONDecoder().decode([EmergencyContact].self, from: data)
        else { return }

        emergencyContacts = decoded
    }
}

struct EmergencyDataRow: View {
    let label: String
    let value: String
    let accentColor: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.system(size: 16, weight: .bold))
                .foregroundColor(accentColor)
            Text(value)
                .font(.system(size: 26, weight: .heavy))
                .foregroundColor(.white)
                .multilineTextAlignment(.leading)
        }
    }
}
