import SwiftUI
import Combine
import FirebaseDatabase
import FirebaseAuth

// MARK: - Maintenance Item Type
// A fixed set — riders can't add/remove checklist items, only edit each
// one's interval. Default intervals are reasonable general-purpose
// motorcycle maintenance ballparks, not model-specific.
enum MaintenanceItemType: String, Codable, CaseIterable, Identifiable {
    case oil, chain, tires, brakes, valves

    var id: String { rawValue }

    var label: String {
        switch self {
        case .oil: return "Oil Change"
        case .chain: return "Chain"
        case .tires: return "Tires"
        case .brakes: return "Brakes"
        case .valves: return "Valves"
        }
    }

    var icon: String {
        switch self {
        case .oil: return "drop.fill"
        case .chain: return "link"
        case .tires: return "circle.dashed"
        case .brakes: return "hand.raised.fill"
        case .valves: return "gauge"
        }
    }

    var defaultIntervalMiles: Double {
        switch self {
        case .oil: return 3000
        case .chain: return 500
        case .tires: return 5000
        case .brakes: return 8000
        case .valves: return 15000
        }
    }
}

// MARK: - Maintenance Item
struct MaintenanceItem: Codable, Identifiable {
    var id: String = UUID().uuidString
    var type: MaintenanceItemType
    var intervalMiles: Double
    var lastServiceMileage: Double

    init(type: MaintenanceItemType, intervalMiles: Double? = nil, lastServiceMileage: Double) {
        self.type = type
        self.intervalMiles = intervalMiles ?? type.defaultIntervalMiles
        self.lastServiceMileage = lastServiceMileage
    }
}

// MARK: - Bike Model
// Aug 27, 2026 — was local-only (UserDefaults, never left the device); now
// also synced to Firebase (see BikeManager below), same "users/{uid}/..."
// pattern as ride history / crash alerts / ride invites.
struct Bike: Codable, Identifiable {
    var id: String
    var nickname: String
    var make: String
    var model: String
    var year: String
    var baselineOdometer: Double
    var isActive: Bool
    var maintenanceItems: [MaintenanceItem]

    init(id: String = UUID().uuidString, nickname: String, make: String, model: String, year: String,
         baselineOdometer: Double, isActive: Bool = false, maintenanceItems: [MaintenanceItem]? = nil) {
        self.id = id
        self.nickname = nickname
        self.make = make
        self.model = model
        self.year = year
        self.baselineOdometer = baselineOdometer
        self.isActive = isActive
        // A brand new bike's "last serviced" starting point is its baseline
        // odometer — there's no earlier service history PackRide knows about.
        self.maintenanceItems = maintenanceItems ?? MaintenanceItemType.allCases.map {
            MaintenanceItem(type: $0, lastServiceMileage: baselineOdometer)
        }
    }
}

// MARK: - Bike Manager
class BikeManager: ObservableObject {
    @Published var bikes: [Bike] = []
    private static let storageKey = "pr_garage_bikes"

    init() {
        loadBikes()
        // A reinstall — or, per Karthik's report, even a plain sign-out/
        // sign-in — left the garage empty even though the bikes were still
        // added under this account, because nothing about it was ever
        // written to Firebase. Same bug class already fixed for ride
        // history and profile; this pulls back anything this account has
        // in the cloud that isn't already here locally.
        syncFromCloud()
    }

    func loadBikes() {
        if let data = UserDefaults.standard.data(forKey: Self.storageKey),
           let decoded = try? JSONDecoder().decode([Bike].self, from: data) {
            bikes = decoded
        }
    }

    private func saveBikes() {
        if let encoded = try? JSONEncoder().encode(bikes) {
            UserDefaults.standard.set(encoded, forKey: Self.storageKey)
        }
        syncBikesToCloud()
    }

    // Mirrors RideHistoryManager's cloud-sync shape — per-bike keyed under
    // users/{uid}/garage/{bikeId}, not one bulk array (Realtime Database
    // arrays get flaky once entries are removed out of order). Bikes are
    // small and few, so re-pushing the whole current list on every save —
    // rather than tracking exactly which single bike changed through
    // setActive/markServiced/updateInterval — keeps every call site simple
    // and is still cheap.
    private func syncBikesToCloud() {
        guard let uid = Auth.auth().currentUser?.uid else { return }
        let ref = Database.database().reference().child("users").child(uid).child("garage")
        for bike in bikes {
            guard let data = try? JSONEncoder().encode(bike),
                  let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            ref.child(bike.id).setValue(dict)
        }
    }

    private func deleteBikeFromCloud(id: String) {
        guard let uid = Auth.auth().currentUser?.uid else { return }
        Database.database().reference().child("users").child(uid).child("garage").child(id).removeValue()
    }

    /// One-shot pull of every bike this account has in the cloud that isn't
    /// already in `bikes` (matched by id) — new install, new device, or a
    /// sign-out/sign-in that lost the local copy. Doesn't touch bikes
    /// already present locally, so an in-progress local edit can't be
    /// clobbered by a stale server copy.
    func syncFromCloud() {
        guard let uid = Auth.auth().currentUser?.uid else { return }
        Database.database().reference().child("users").child(uid).child("garage")
            .observeSingleEvent(of: .value) { [weak self] snapshot in
                guard let self, let children = snapshot.value as? [String: Any] else { return }
                DispatchQueue.main.async {
                    var didAdd = false
                    for (id, value) in children {
                        guard !self.bikes.contains(where: { $0.id == id }),
                              let dict = value as? [String: Any],
                              let data = try? JSONSerialization.data(withJSONObject: dict),
                              let bike = try? JSONDecoder().decode(Bike.self, from: data)
                        else { continue }
                        self.bikes.append(bike)
                        didAdd = true
                    }
                    guard didAdd else { return }
                    // A restored garage should never end up with zero active
                    // bikes (breaks bikeId tagging on the next recorded ride)
                    // — if nothing locally-missing was marked active either,
                    // promote the first restored bike.
                    if !self.bikes.contains(where: { $0.isActive }), let firstID = self.bikes.first?.id {
                        for i in self.bikes.indices { self.bikes[i].isActive = (self.bikes[i].id == firstID) }
                    }
                    if let encoded = try? JSONEncoder().encode(self.bikes) {
                        UserDefaults.standard.set(encoded, forKey: Self.storageKey)
                    }
                }
            }
    }

    // Non-reactive lookup for the ride/lap recording call sites (SoloRideView,
    // GroupRideView, MapView, LapModeView) — those don't otherwise need a
    // BikeManager instance around, so this reads straight from UserDefaults,
    // same "static func" pattern RideHistoryManager.recordRide already uses.
    static func currentActiveBikeID() -> String? {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let decoded = try? JSONDecoder().decode([Bike].self, from: data) else { return nil }
        return decoded.first(where: { $0.isActive })?.id
    }

    // The first bike ever added becomes active automatically; every bike
    // after that stays inactive until explicitly set active.
    func addBike(_ bike: Bike) {
        var newBike = bike
        if bikes.isEmpty { newBike.isActive = true }
        bikes.append(newBike)
        saveBikes()
    }

    func updateBike(_ bike: Bike) {
        guard let idx = bikes.firstIndex(where: { $0.id == bike.id }) else { return }
        bikes[idx] = bike
        saveBikes()
    }

    // Deleting a bike only removes the bike record — rides/lap sessions
    // already tagged with its id are left alone (they just point at an id
    // that no longer resolves to a bike). Deleting the active bike promotes
    // the next remaining one so there's never an ambiguous "no active bike"
    // state while bikes still exist.
    func deleteBike(id: String) {
        let wasActive = bikes.first(where: { $0.id == id })?.isActive ?? false
        bikes.removeAll { $0.id == id }
        if wasActive, !bikes.isEmpty {
            bikes[0].isActive = true
        }
        saveBikes()
        deleteBikeFromCloud(id: id)
    }

    func setActive(id: String) {
        for i in bikes.indices { bikes[i].isActive = (bikes[i].id == id) }
        saveBikes()
    }

    func markServiced(bikeId: String, itemType: MaintenanceItemType, currentMileage: Double) {
        guard let bIdx = bikes.firstIndex(where: { $0.id == bikeId }),
              let iIdx = bikes[bIdx].maintenanceItems.firstIndex(where: { $0.type == itemType }) else { return }
        bikes[bIdx].maintenanceItems[iIdx].lastServiceMileage = currentMileage
        saveBikes()
    }

    func updateInterval(bikeId: String, itemType: MaintenanceItemType, intervalMiles: Double) {
        guard let bIdx = bikes.firstIndex(where: { $0.id == bikeId }),
              let iIdx = bikes[bIdx].maintenanceItems.firstIndex(where: { $0.type == itemType }) else { return }
        bikes[bIdx].maintenanceItems[iIdx].intervalMiles = intervalMiles
        saveBikes()
    }

    // Total mileage = baseline odometer + the distance of every ride/lap
    // session tagged to this bike. Recomputed on demand rather than kept as
    // a running total, so it can't drift out of sync with Ride History.
    func totalMileage(for bike: Bike, rides: [RideRecord], lapSessions: [LapRecord]) -> Double {
        let rideMiles = rides.filter { $0.bikeId == bike.id }.reduce(0) { $0 + $1.distance }
        let lapMiles = lapSessions.filter { $0.bikeId == bike.id }.reduce(0) { $0 + $1.totalDistance }
        return bike.baselineOdometer + rideMiles + lapMiles
    }
}

// MARK: - Interval Edit Target (sheet(item:) needs Identifiable)
private struct IntervalEditTarget: Identifiable {
    let id = UUID()
    let bikeId: String
    let item: MaintenanceItem
}

// MARK: - Garage View
struct GarageView: View {
    @AppStorage(MeasurementUnits.preferenceKey) private var measurementSystem = MeasurementSystem.imperial.rawValue
    @StateObject private var bikeManager = BikeManager()
    @StateObject private var historyManager = RideHistoryManager()
    @StateObject private var lapHistoryManager = LapHistoryManager()

    @State private var showAddBike = false
    @State private var editingBike: Bike? = nil
    @State private var intervalEditTarget: IntervalEditTarget? = nil

    var body: some View {
        ZStack {
            Color.prBg.ignoresSafeArea()

            ScrollView(showsIndicators: false) {
                VStack(spacing: 0) {
                    PRWebPageHeader(
                        eyebrow: "Garage",
                        title: "Your Machines",
                        subtitle: bikeManager.bikes.isEmpty
                            ? "Keep every bike ready for the next road."
                            : "\(bikeManager.bikes.count) bike\(bikeManager.bikes.count == 1 ? "" : "s") in your garage"
                    )

                    if !bikeManager.bikes.isEmpty {
                        let activeBike = bikeManager.bikes.first(where: { $0.isActive })
                        let activeMileage = activeBike.map {
                            bikeManager.totalMileage(for: $0, rides: historyManager.rides, lapSessions: lapHistoryManager.sessions)
                        } ?? 0

                        PRWebMetricStrip(metrics: [
                            ("\(bikeManager.bikes.count)", "Bikes"),
                            (MeasurementUnits.distanceMiles(historyManager.totalMiles, decimals: 0), "Ride Distance"),
                            (MeasurementUnits.distanceMiles(activeMileage, decimals: 0), "Active Odo")
                        ])
                    }

                    PRWebSectionLabel(
                        title: bikeManager.bikes.isEmpty ? "Start Here" : "Garage",
                        detail: bikeManager.bikes.isEmpty ? nil : "Maintenance + mileage"
                    )

                    if bikeManager.bikes.isEmpty {
                        emptyState
                            .padding(.horizontal, 16)
                    } else {
                        VStack(spacing: 14) {
                            ForEach(bikeManager.bikes) { bike in
                                BikeCard(
                                    bike: bike,
                                    totalMileage: bikeManager.totalMileage(for: bike, rides: historyManager.rides, lapSessions: lapHistoryManager.sessions),
                                    onSetActive: { bikeManager.setActive(id: bike.id) },
                                    onEdit: { editingBike = bike },
                                    onDelete: { bikeManager.deleteBike(id: bike.id) },
                                    onServiced: { itemType in
                                        let mileage = bikeManager.totalMileage(for: bike, rides: historyManager.rides, lapSessions: lapHistoryManager.sessions)
                                        bikeManager.markServiced(bikeId: bike.id, itemType: itemType, currentMileage: mileage)
                                    },
                                    onEditInterval: { item in
                                        intervalEditTarget = IntervalEditTarget(bikeId: bike.id, item: item)
                                    }
                                )
                                .padding(.horizontal, 16)
                            }
                        }
                    }

                    Button(action: { showAddBike = true }) {
                        HStack(spacing: 10) {
                            Image(systemName: "plus")
                                .font(.system(size: 13, weight: .bold))
                            Text("ADD BIKE")
                                .font(.system(size: 13, weight: .heavy))
                                .tracking(1.4)
                            Spacer()
                            Image(systemName: "arrow.right")
                                .font(.system(size: 12, weight: .bold))
                        }
                        .foregroundColor(.white)
                        .padding(.horizontal, 16)
                        .frame(height: 50)
                        .background(Color.prCoral)
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 16)
                    .padding(.bottom, 32)
                }
            }
        }
        .navigationBarHidden(true)
        .sheet(isPresented: $showAddBike) {
            AddEditBikeSheet(
                existing: nil,
                onSave: { bike in bikeManager.addBike(bike); showAddBike = false },
                onCancel: { showAddBike = false }
            )
        }
        .sheet(item: $editingBike) { bike in
            AddEditBikeSheet(
                existing: bike,
                onSave: { updated in bikeManager.updateBike(updated); editingBike = nil },
                onCancel: { editingBike = nil }
            )
        }
        .sheet(item: $intervalEditTarget) { target in
            EditIntervalSheet(
                item: target.item,
                onSave: { newInterval in
                    bikeManager.updateInterval(bikeId: target.bikeId, itemType: target.item.type, intervalMiles: newInterval)
                    intervalEditTarget = nil
                },
                onCancel: { intervalEditTarget = nil }
            )
        }
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            ZStack {
                Circle().fill(Color.prCoralSoft).frame(width: 80, height: 80)
                Image(systemName: "motorcycle").font(.system(size: 30)).foregroundColor(.prCoral)
            }
            Text("No bikes yet").font(.system(size: 16, weight: .bold)).foregroundColor(.prInk)
            Text("Add your first bike to start tracking mileage and maintenance.")
                .font(.system(size: 13)).foregroundColor(.prMuted)
                .multilineTextAlignment(.center).padding(.horizontal, 32)
        }
        .padding(.vertical, 40).frame(maxWidth: .infinity)
        .background(Color.prCardBg)
        .overlay(RoundedRectangle(cornerRadius: 20).stroke(Color.prBorder, lineWidth: 1))
        .cornerRadius(20).padding(.horizontal, 16)
    }
}

// MARK: - Bike Card
struct BikeCard: View {
    let bike: Bike
    let totalMileage: Double
    let onSetActive: () -> Void
    let onEdit: () -> Void
    let onDelete: () -> Void
    let onServiced: (MaintenanceItemType) -> Void
    let onEditInterval: (MaintenanceItem) -> Void

    @State private var showDeleteConfirm = false

    private var bikeSubtitle: String {
        let parts = [bike.year, bike.make, bike.model].filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        return parts.isEmpty ? "No details added" : parts.joined(separator: " ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header

            Divider().background(Color.prBorder)

            VStack(alignment: .leading, spacing: 2) {
                Text("TOTAL MILEAGE").font(.system(size: 10, weight: .heavy)).foregroundColor(.prMuted).tracking(1)
                Text(MeasurementUnits.distanceMiles(totalMileage, decimals: 0))
                    .font(.system(size: 22, weight: .bold, design: .monospaced)).foregroundColor(.prInk)
            }

            Divider().background(Color.prBorder)

            VStack(alignment: .leading, spacing: 10) {
                Text("MAINTENANCE").font(.system(size: 11, weight: .heavy)).foregroundColor(.prMuted).tracking(1.5)
                VStack(spacing: 8) {
                    ForEach(bike.maintenanceItems) { item in
                        MaintenanceRow(
                            item: item,
                            currentMileage: totalMileage,
                            onServiced: { onServiced(item.type) },
                            onEditInterval: { onEditInterval(item) }
                        )
                    }
                }
            }

            if !bike.isActive {
                Button(action: onSetActive) {
                    Text("Set as Active Bike")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 13)
                        .background(Color.prCoral)
                        .cornerRadius(12)
                }
            }
        }
        .padding(18)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 20))
        .overlay(
            RoundedRectangle(cornerRadius: 20)
                .stroke(bike.isActive ? Color.prCoral.opacity(0.8) : Color.prBorder, lineWidth: bike.isActive ? 1.5 : 1)
        )
        .alert("Delete \(bike.nickname)?", isPresented: $showDeleteConfirm) {
            Button("Delete", role: .destructive) { onDelete() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes the bike from your Garage. Rides already logged to it stay in your history.")
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                Circle().fill(bike.isActive ? Color.prCoralSoft : Color.prFieldBg).frame(width: 50, height: 50)
                Image(systemName: "motorcycle").font(.system(size: 20)).foregroundColor(bike.isActive ? .prCoral : .prMuted)
            }
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(bike.nickname).font(.system(size: 16, weight: .bold)).foregroundColor(.prInk)
                    if bike.isActive {
                        Text("ACTIVE")
                            .font(.system(size: 9, weight: .heavy)).tracking(0.5)
                            .foregroundColor(.white)
                            .padding(.horizontal, 7).padding(.vertical, 3)
                            .background(Color.prCoral).cornerRadius(6)
                    }
                }
                Text(bikeSubtitle).font(.system(size: 13)).foregroundColor(.prMuted)
            }
            Spacer()
            Button(action: onEdit) {
                Image(systemName: "pencil").foregroundColor(.prCoral)
                    .padding(8).background(Color.prCoralSoft).cornerRadius(8)
            }
            Button(action: { showDeleteConfirm = true }) {
                Image(systemName: "trash").foregroundColor(Color(red: 0.827, green: 0.231, blue: 0.173))
                    .padding(8).background(Color(red: 0.988, green: 0.922, blue: 0.906)).cornerRadius(8)
            }
        }
    }
}

// MARK: - Maintenance Row
// Color-graded: green with plenty of interval left, amber getting close,
// red once overdue. "Serviced" resets lastServiceMileage to the bike's
// current computed mileage; tapping the interval opens EditIntervalSheet.
struct MaintenanceRow: View {
    let item: MaintenanceItem
    let currentMileage: Double
    let onServiced: () -> Void
    let onEditInterval: () -> Void

    private var used: Double { max(0, currentMileage - item.lastServiceMileage) }
    private var remaining: Double { item.intervalMiles - used }
    private var isOverdue: Bool { remaining < 0 }

    private var statusColor: Color {
        if isOverdue { return Color(red: 0.827, green: 0.231, blue: 0.173) }
        if remaining <= item.intervalMiles * 0.2 { return .orange }
        return Color(red: 0.180, green: 0.620, blue: 0.357)
    }

    private var statusText: String {
        isOverdue ? "Overdue by \(MeasurementUnits.distanceMiles(-remaining, decimals: 0))" : "\(MeasurementUnits.distanceMiles(remaining, decimals: 0)) left"
    }

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle().fill(statusColor.opacity(0.15)).frame(width: 36, height: 36)
                Image(systemName: item.type.icon).font(.system(size: 14)).foregroundColor(statusColor)
            }
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(item.type.label).font(.system(size: 13, weight: .semibold)).foregroundColor(.prInk)
                    Button(action: onEditInterval) {
                        Text("every \(MeasurementUnits.distanceMiles(item.intervalMiles, decimals: 0))")
                            .font(.system(size: 11)).foregroundColor(.prMuted).underline()
                    }
                }
                Text(statusText).font(.system(size: 12, weight: .bold)).foregroundColor(statusColor)
            }
            Spacer()
            Button(action: onServiced) {
                Text("Serviced")
                    .font(.system(size: 12, weight: .semibold)).foregroundColor(.prTeal)
                    .padding(.horizontal, 10).padding(.vertical, 7)
                    .background(Color(red: 0.906, green: 0.937, blue: 0.945))
                    .cornerRadius(8)
            }
        }
        .padding(10)
        .background(Color.prFieldBg)
        .cornerRadius(12)
    }
}

// MARK: - Edit Interval Sheet
struct EditIntervalSheet: View {
    let item: MaintenanceItem
    let onSave: (Double) -> Void
    let onCancel: () -> Void

    @State private var intervalText: String = ""

    private var enteredValue: Double? { Double(intervalText) }

    var body: some View {
        ZStack {
            Color.prBg.ignoresSafeArea()
            VStack(spacing: 20) {
                RoundedRectangle(cornerRadius: 3).fill(Color.prBorder)
                    .frame(width: 40, height: 5).padding(.top, 12)

                VStack(spacing: 6) {
                    Text("Edit \(item.type.label) Interval").font(.system(size: 19, weight: .bold)).foregroundColor(.prInk)
                    Text("How many \(MeasurementUnits.current == .metric ? "kilometres" : "miles") between services.").font(.system(size: 13)).foregroundColor(.prMuted)
                }

                HStack(spacing: 12) {
                    Image(systemName: item.type.icon).foregroundColor(.prCoral).frame(width: 20)
                    TextField("", text: $intervalText, prompt: Text(MeasurementUnits.current == .metric ? "Kilometres" : "Miles").foregroundColor(.prMuted))
                        .foregroundColor(.prInk)
                        .keyboardType(.numberPad)
                    Text(MeasurementUnits.distanceInputLabel).font(.system(size: 14)).foregroundColor(.prMuted)
                }
                .padding(16).background(Color.prCardBg).overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.prBorder, lineWidth: 1)).cornerRadius(14)
                .padding(.horizontal, 24)

                Spacer()

                VStack(spacing: 12) {
                    Button(action: {
                        guard let value = enteredValue, value > 0 else { return }
                        onSave(MeasurementUnits.displayDistanceToMiles(value))
                    }) {
                        Text("Save")
                            .font(.system(size: 16, weight: .bold)).foregroundColor(.white)
                            .frame(maxWidth: .infinity).padding(.vertical, 16)
                            .background((enteredValue ?? 0) > 0 ? Color.prCoral : Color.prCoral.opacity(0.4))
                            .cornerRadius(14)
                    }
                    .disabled(!((enteredValue ?? 0) > 0))

                    Button(action: onCancel) {
                        Text("Cancel").font(.system(size: 14)).foregroundColor(.prMuted)
                    }
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 36)
            }
        }
        .onAppear { intervalText = String(Int(MeasurementUnits.milesToDisplay(item.intervalMiles))) }
    }
}

// MARK: - Add/Edit Bike Sheet
struct AddEditBikeSheet: View {
    let existing: Bike?
    let onSave: (Bike) -> Void
    let onCancel: () -> Void

    @State private var nickname = ""
    @State private var make = ""
    @State private var model = ""
    @State private var year = ""
    @State private var odometerText = ""

    private var isValid: Bool {
        !nickname.trimmingCharacters(in: .whitespaces).isEmpty && Double(odometerText) != nil
    }

    var body: some View {
        ZStack {
            Color.prBg.ignoresSafeArea()
            VStack(spacing: 0) {
                RoundedRectangle(cornerRadius: 3).fill(Color.prBorder)
                    .frame(width: 40, height: 5).padding(.top, 12).padding(.bottom, 20)

                Text(existing == nil ? "Add Bike" : "Edit Bike")
                    .font(.system(size: 19, weight: .bold)).foregroundColor(.prInk).padding(.bottom, 16)

                ScrollView {
                    VStack(spacing: 14) {
                        field(icon: "tag.fill", placeholder: "Nickname (e.g. \"The Beast\")", text: $nickname)
                        field(icon: "building.2.fill", placeholder: "Make (e.g. Yamaha)", text: $make)
                        field(icon: "arrowtriangle.up.fill", placeholder: "Model (e.g. MT-07)", text: $model)
                        field(icon: "calendar", placeholder: "Year", text: $year, keyboard: .numberPad)
                        field(icon: "gauge", placeholder: "Starting odometer (\(MeasurementUnits.distanceInputLabel))", text: $odometerText, keyboard: .numberPad)

                        Text("The mileage already on this bike before you started tracking it in PackRide.")
                            .font(.system(size: 11)).foregroundColor(.prMuted).lineSpacing(2)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(.horizontal, 24)
                }

                VStack(spacing: 12) {
                    Button(action: save) {
                        Text(existing == nil ? "Add Bike" : "Save Changes")
                            .font(.system(size: 16, weight: .bold))
                            .foregroundColor(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 16)
                            .background(isValid ? Color.prCoral : Color.prCoral.opacity(0.4))
                            .cornerRadius(14)
                    }
                    .disabled(!isValid)

                    Button(action: onCancel) {
                        Text("Cancel").font(.system(size: 14)).foregroundColor(.prMuted)
                    }
                }
                .padding(.horizontal, 24)
                .padding(.top, 16)
                .padding(.bottom, 36)
            }
        }
        .onAppear {
            if let existing {
                nickname = existing.nickname
                make = existing.make
                model = existing.model
                year = existing.year
                odometerText = String(Int(MeasurementUnits.milesToDisplay(existing.baselineOdometer)))
            }
        }
    }

    private func field(icon: String, placeholder: String, text: Binding<String>, keyboard: UIKeyboardType = .default) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon).foregroundColor(.prCoral).frame(width: 20)
            TextField("", text: text, prompt: Text(placeholder).foregroundColor(.prMuted))
                .foregroundColor(.prInk)
                .keyboardType(keyboard)
        }
        .padding(16).background(Color.prCardBg).overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.prBorder, lineWidth: 1)).cornerRadius(14)
    }

    // Editing an existing bike whose starting odometer changes shifts every
    // checklist item's lastServiceMileage by the same delta, so the "miles
    // since service" gap each item represents doesn't silently change out
    // from under the rider just because they corrected the starting number.
    // A brand new bike instead goes through Bike's own initializer, which
    // seeds every checklist item's lastServiceMileage at the chosen starting
    // odometer directly.
    private func save() {
        let trimmedNickname = nickname.trimmingCharacters(in: .whitespaces)
        let trimmedMake = make.trimmingCharacters(in: .whitespaces)
        let trimmedModel = model.trimmingCharacters(in: .whitespaces)
        let trimmedYear = year.trimmingCharacters(in: .whitespaces)
        let newOdometer = MeasurementUnits.displayDistanceToMiles(Double(odometerText) ?? 0)

        if var bike = existing {
            let delta = newOdometer - bike.baselineOdometer
            if delta != 0 {
                for i in bike.maintenanceItems.indices {
                    bike.maintenanceItems[i].lastServiceMileage += delta
                }
            }
            bike.nickname = trimmedNickname
            bike.make = trimmedMake
            bike.model = trimmedModel
            bike.year = trimmedYear
            bike.baselineOdometer = newOdometer
            onSave(bike)
        } else {
            let bike = Bike(nickname: trimmedNickname, make: trimmedMake, model: trimmedModel, year: trimmedYear, baselineOdometer: newOdometer)
            onSave(bike)
        }
    }
}

#Preview {
    NavigationView { GarageView() }
}
