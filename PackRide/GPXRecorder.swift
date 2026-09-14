import Foundation
import Combine
import CoreLocation
import CoreMotion

// MARK: - GPX File Resolution
// GPX files are always looked up fresh, relative to the CURRENT app container's
// Documents directory — never trust a stored absolute path directly. iOS can (and
// does) assign a brand-new container across rebuilds/reinstalls from Xcode, which
// silently invalidates any absolute path saved to UserDefaults from a previous
// build — the exact reason "Export GPX" / route buttons went permanently gray.
// Storing/looking up by filename only, resolved at call time, survives that.
enum GPXStorage {
    static var ridesDirectory: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        return docs.appendingPathComponent("rides", isDirectory: true)
    }

    /// Accepts either a bare filename (current format) or a legacy full path saved
    /// by an older build, and resolves it against the CURRENT container.
    static func resolve(_ stored: String) -> URL {
        let filename = (stored as NSString).lastPathComponent
        return ridesDirectory.appendingPathComponent(filename)
    }

    static func exists(_ stored: String) -> Bool {
        FileManager.default.fileExists(atPath: resolve(stored).path)
    }

    static func contents(_ stored: String) -> Data? {
        FileManager.default.contents(atPath: resolve(stored).path)
    }

    static func remove(_ stored: String) {
        try? FileManager.default.removeItem(at: resolve(stored))
    }

    // Aug 27, 2026 — writes GPX bytes fetched from Firebase Storage (a ride
    // recorded on a different install of this account, or a reinstall of
    // this one — see RideHistoryManager.resolveGPXPath) to this container's
    // rides directory under a filename keyed to the ride's id, so it's
    // findable/overwritable on repeat downloads and everything downstream
    // (map, replay, telemetry, export) treats it exactly like a locally
    // recorded file.
    static func saveDownloaded(_ data: Data, rideID: String) -> String? {
        let fm = FileManager.default
        if !fm.fileExists(atPath: ridesDirectory.path) {
            try? fm.createDirectory(at: ridesDirectory, withIntermediateDirectories: true)
        }
        let filename = "\(rideID)_restored.gpx"
        let fileURL = ridesDirectory.appendingPathComponent(filename)
        do {
            try data.write(to: fileURL, options: .atomic)
            return filename
        } catch {
            print("Failed to save downloaded GPX: \(error)")
            return nil
        }
    }

    // Aug 22, 2026 — bug #11: a participant's actual GPX only ever exists on
    // THEIR phone, but the leader (or anyone) can now fetch that rider's
    // synced position breadcrumbs from Firebase (see FirebaseManager.fetchTrack)
    // and needs to feed them into the existing RideReplayView, which only
    // knows how to read a local GPX file. Rather than teach that view a
    // second data source, this writes the fetched breadcrumbs out as a
    // regular (if sparser — no elevation/G-force, since the live-map pings
    // never carried those) GPX file, so everything downstream — replay,
    // "View Route on Map", export — just works unmodified.
    static func synthesizeGPX(from points: [FirebaseTrackPoint], rideName: String) -> String? {
        guard !points.isEmpty else { return nil }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        let startISO = iso.string(from: Date(timeIntervalSince1970: points.first!.timestamp))

        var xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <gpx version="1.1" creator="PackRide iOS"
             xmlns="http://www.topografix.com/GPX/1/1"
             xmlns:packride="http://packride.app/gpx/1.0">
          <metadata>
            <name>\(rideName)</name>
            <time>\(startISO)</time>
          </metadata>
          <trk>
            <name>\(rideName)</name>
            <trkseg>

        """
        for point in points {
            let timeISO = iso.string(from: Date(timeIntervalSince1970: point.timestamp))
            xml += """
              <trkpt lat="\(point.lat)" lon="\(point.lng)">
                <ele>0.00</ele>
                <time>\(timeISO)</time>
                <speed>\(String(format: "%.2f", point.speed))</speed>
                <extensions>
                  <packride:gforce>1.00</packride:gforce>
                  <packride:lean>0.0</packride:lean>
                </extensions>
              </trkpt>

            """
        }
        xml += """
            </trkseg>
          </trk>
        </gpx>
        """

        let fm = FileManager.default
        if !fm.fileExists(atPath: ridesDirectory.path) {
            try? fm.createDirectory(at: ridesDirectory, withIntermediateDirectories: true)
        }
        let dateStr = ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: points.first!.timestamp))
            .replacingOccurrences(of: ":", with: "-")
        let filename = "\(rideName.replacingOccurrences(of: " ", with: "_"))_synced_\(dateStr).gpx"
        let fileURL = ridesDirectory.appendingPathComponent(filename)
        do {
            try xml.write(to: fileURL, atomically: true, encoding: .utf8)
            return filename
        } catch {
            print("Failed to synthesize GPX from synced track: \(error)")
            return nil
        }
    }
}

// MARK: - Track Point
struct GPXTrackPoint {
    let latitude: Double
    let longitude: Double
    let elevation: Double      // meters
    let speed: Double          // meters per second
    let gforce: Double         // 1.0 = normal
    let lean: Double           // degrees, signed (+ right lean / - left lean), 0 = upright
    let timestamp: Date
}

// MARK: - GPX Recorder
class GPXRecorder: ObservableObject {
    @Published var pointCount: Int = 0
    private var points: [GPXTrackPoint] = []
    private var startTime: Date?
    private var rideName: String = "PackRide"
    private var timingPoint: CLLocationCoordinate2D?
    private var lastCaptureTime: Date?
    private var lastAcceptedLocation: CLLocation?
    private let stateLock = NSLock()

    // Current values updated externally
    var currentGForce: Double = 1.0
    var currentLeanAngle: Double = 0

    // MARK: - Start
    func startRecording(rideName: String, timingPoint: CLLocationCoordinate2D? = nil) {
        stateLock.lock()
        self.rideName = rideName
        self.timingPoint = timingPoint
        self.points = []
        self.startTime = Date()
        self.lastCaptureTime = nil
        self.lastAcceptedLocation = nil
        stateLock.unlock()
        DispatchQueue.main.async { self.pointCount = 0 }
    }

    // MARK: - Capture (called on every location update — works in background!)
    func capturePoint(location: CLLocation) {
        stateLock.lock()
        defer { stateLock.unlock() }

        // Pocket/locked-screen testing can briefly yield fixes far off the
        // circuit. Reject weak, stale, or physically implausible points before
        // they become criss-crossing segments in the saved racing line.
        guard location.horizontalAccuracy >= 0, location.horizontalAccuracy <= 25,
              abs(location.timestamp.timeIntervalSinceNow) <= 5 else { return }
        if let last = lastAcceptedLocation {
            let dt = location.timestamp.timeIntervalSince(last.timestamp)
            let step = location.distance(from: last)
            guard dt > 0, step <= max(75, dt * 70) else { return }
        }

        if let last = lastCaptureTime, Date().timeIntervalSince(last) < 0.9 { return }
        lastCaptureTime = Date()

        let point = GPXTrackPoint(
            latitude: location.coordinate.latitude,
            longitude: location.coordinate.longitude,
            elevation: location.altitude,
            speed: max(location.speed, 0),
            gforce: currentGForce,
            lean: currentLeanAngle,
            timestamp: location.timestamp
        )
        points.append(point)
        lastAcceptedLocation = location
        let count = points.count
        DispatchQueue.main.async { self.pointCount = count }
    }

    // MARK: - Stop & Save
    func stopAndSave() -> String? {
        stateLock.lock()
        let snapshot = points
        let savedRideName = rideName
        let savedStartTime = startTime
        let savedTimingPoint = timingPoint
        stateLock.unlock()

        guard !snapshot.isEmpty else { return nil }
        return saveGPXFile(points: snapshot, rideName: savedRideName, startTime: savedStartTime, timingPoint: savedTimingPoint)
    }

    func cancelRecording() {
        stateLock.lock()
        points = []
        lastCaptureTime = nil
        lastAcceptedLocation = nil
        stateLock.unlock()
        DispatchQueue.main.async { self.pointCount = 0 }
    }

    // MARK: - GPX Generation
    private func saveGPXFile(points: [GPXTrackPoint], rideName: String, startTime: Date?, timingPoint: CLLocationCoordinate2D?) -> String? {
        let xml = generateGPXXML(points: points, rideName: rideName, startTime: startTime, timingPoint: timingPoint)
        let fm = FileManager.default
        let rideDir = GPXStorage.ridesDirectory
        if !fm.fileExists(atPath: rideDir.path) {
            do {
                try fm.createDirectory(at: rideDir, withIntermediateDirectories: true)
            } catch {
                print("Failed to create GPX directory: \(error)")
                return nil
            }
        }
        let dateStr = ISO8601DateFormatter().string(from: startTime ?? Date())
            .replacingOccurrences(of: ":", with: "-")
        let filename = "\(rideName.replacingOccurrences(of: " ", with: "_"))_\(dateStr).gpx"
        let fileURL = rideDir.appendingPathComponent(filename)
        do {
            try xml.write(to: fileURL, atomically: true, encoding: .utf8)
            return filename
        } catch {
            print("Failed to save GPX: \(error)")
            return nil
        }
    }

    private func generateGPXXML(points: [GPXTrackPoint], rideName: String, startTime: Date?, timingPoint: CLLocationCoordinate2D?) -> String {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        let startISO = iso.string(from: startTime ?? Date())

        var xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <gpx version="1.1" creator="PackRide iOS"
             xmlns="http://www.topografix.com/GPX/1/1"
             xmlns:packride="http://packride.app/gpx/1.0">
          <metadata>
            <name>\(rideName)</name>
            <time>\(startISO)</time>
          </metadata>
        \(timingPoint.map { "  <wpt lat=\"\($0.latitude)\" lon=\"\($0.longitude)\"><name>PackRide Start/Finish</name><type>start-finish</type></wpt>" } ?? "")
          <trk>
            <name>\(rideName)</name>
            <trkseg>

        """

        for point in points {
            let timeISO = iso.string(from: point.timestamp)
            xml += """
              <trkpt lat="\(point.latitude)" lon="\(point.longitude)">
                <ele>\(String(format: "%.2f", point.elevation))</ele>
                <time>\(timeISO)</time>
                <speed>\(String(format: "%.2f", point.speed))</speed>
                <extensions>
                  <packride:gforce>\(String(format: "%.2f", point.gforce))</packride:gforce>
                  <packride:lean>\(String(format: "%.1f", point.lean))</packride:lean>
                </extensions>
              </trkpt>

            """
        }

        xml += """
            </trkseg>
          </trk>
        </gpx>
        """
        return xml
    }
}
