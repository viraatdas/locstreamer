import CoreLocation
import Foundation
import Observation

/// Records location continuously and ships it to the server in batches.
///
/// Recording: standard updates at ~100 m accuracy with a 25 m distance filter
/// (a good battery/coverage trade-off for a whole-day trail), plus significant-
/// change monitoring so iOS relaunches the app after it is killed, plus a
/// heartbeat that re-records the last fix while stationary.
///
/// Uploading: points are appended to a JSON file on disk first (nothing is
/// lost if the upload fails or the app dies) and flushed every 60 s or every
/// 25 points, whichever comes first. Uploaded points are dropped from disk.
@MainActor
@Observable
final class LocationStreamer: NSObject, CLLocationManagerDelegate {
    private(set) var authorization: CLAuthorizationStatus = .notDetermined
    private(set) var recent: [LocationPoint] = []
    private(set) var pending: Int = 0
    private(set) var totalRecorded: Int = 0
    private(set) var lastUpload: Date?
    private(set) var lastError: String?
    private(set) var isRunning = false

    private let manager = CLLocationManager()
    private let api = API()
    private var session: Session?
    private var lastLocation: CLLocation?
    private var buffer: [LocationPoint] = []
    private var uploadTimer: Timer?
    private var heartbeatTimer: Timer?
    private var uploading = false

    private static let bufferURL: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("pending-points.json")
    }()

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
        manager.distanceFilter = 25
        manager.pausesLocationUpdatesAutomatically = false
        manager.activityType = .other
        manager.showsBackgroundLocationIndicator = true
        authorization = manager.authorizationStatus
        if let data = try? Data(contentsOf: Self.bufferURL),
           let saved = try? JSONDecoder().decode([LocationPoint].self, from: data) {
            buffer = saved
            pending = saved.count
        }
    }

    var hasAlwaysAuthorization: Bool { authorization == .authorizedAlways }

    /// Location is already granted at some level — safe to resume recording
    /// without prompting. Used to distinguish reboot-before-unlock (authorized)
    /// from a fresh install (not determined).
    var isAuthorized: Bool {
        authorization == .authorizedAlways || authorization == .authorizedWhenInUse
    }

    /// Begins recording location — independent of having a session. Called on
    /// every launch, including the silent SLC relaunches iOS performs after the
    /// app is killed. If the device rebooted and hasn't been unlocked yet, the
    /// keychain read for the session fails, but recording must still start and
    /// SLC monitoring must be re-registered in this process; `flush()` retries
    /// `Session.restore()` and uploads the buffered points once unlock happens.
    func startRecording() {
        if authorization == .notDetermined {
            manager.requestWhenInUseAuthorization()
        } else if authorization == .authorizedWhenInUse {
            manager.requestAlwaysAuthorization()
        }
        guard !isRunning else { return }
        isRunning = true
        manager.allowsBackgroundLocationUpdates = true
        manager.startUpdatingLocation()
        manager.startMonitoringSignificantLocationChanges()
        uploadTimer = Timer.scheduledTimer(withTimeInterval: Config.uploadInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.flush() }
        }
        heartbeatTimer = Timer.scheduledTimer(withTimeInterval: Config.heartbeatInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.heartbeat() }
        }
        Task { await flush() }
    }

    /// Supplies the session for uploads. Recording may already be running.
    func attach(session: Session) {
        self.session = session
        Task { await flush() }
    }

    func start(session: Session) {
        self.session = session
        startRecording()
    }

    /// Full stop AND wipe: used on sign-out. The pending buffer belongs to the
    /// signed-out phone; leaving it on disk would upload it under the next
    /// account's token, so it is cleared here.
    func stop() {
        isRunning = false
        manager.stopUpdatingLocation()
        manager.stopMonitoringSignificantLocationChanges()
        uploadTimer?.invalidate(); uploadTimer = nil
        heartbeatTimer?.invalidate(); heartbeatTimer = nil
        session = nil
        lastLocation = nil
        buffer.removeAll()
        recent.removeAll()
        pending = 0
        totalRecorded = 0
        try? FileManager.default.removeItem(at: Self.bufferURL)
    }

    func requestAlways() {
        manager.requestAlwaysAuthorization()
    }

    // MARK: - CLLocationManagerDelegate

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        Task { @MainActor in
            self.authorization = status
            // Step up from "While Using" to "Always" as soon as we can ask.
            if status == .authorizedWhenInUse { self.manager.requestAlwaysAuthorization() }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        Task { @MainActor in
            for location in locations where location.horizontalAccuracy >= 0 && location.horizontalAccuracy < 500 {
                self.record(LocationPoint(location))
                self.lastLocation = location
                // A fix arriving clears the transient "location unknown" Core Location reports at startup.
                if self.lastUpload == nil || self.pending > 0 { self.lastError = nil }
            }
            if self.buffer.count >= Config.uploadBatchSize { await self.flush() }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor in self.lastError = error.localizedDescription }
    }

    // MARK: - Recording + upload

    private func heartbeat() {
        guard let last = lastLocation else { return }
        record(LocationPoint(last, at: Date()))
    }

    private func record(_ point: LocationPoint) {
        buffer.append(point)
        pending = buffer.count
        totalRecorded += 1
        recent.insert(point, at: 0)
        if recent.count > 200 { recent.removeLast(recent.count - 200) }
        persistBuffer()
    }

    func flush() async {
        // Recover a session that couldn't be read at launch (device rebooted,
        // keychain still locked). Once it restores, buffered points upload.
        if session == nil { session = Session.restore() }
        guard let session, !uploading, !buffer.isEmpty else { return }
        uploading = true
        defer { uploading = false }
        let batch = Array(buffer.prefix(1000))
        do {
            try await api.upload(batch, token: session.token)
            buffer.removeFirst(batch.count)
            pending = buffer.count
            lastUpload = Date()
            lastError = nil
            persistBuffer()
        } catch let API.APIError.http(status, message) where status != 401 && (400..<500).contains(status) {
            // The server rejected this batch for a reason retrying won't fix
            // (e.g. every point out of range). Drop it so it can't block the
            // queue forever; keep going with the rest. 401 is excluded: that's
            // an expired session, which a re-sign-in resolves.
            buffer.removeFirst(batch.count)
            pending = buffer.count
            lastError = "Dropped \(batch.count) unsendable point(s): \(message)"
            persistBuffer()
        } catch {
            lastError = error.localizedDescription
        }
    }

    private func persistBuffer() {
        if let data = try? JSONEncoder().encode(buffer) {
            try? data.write(to: Self.bufferURL, options: .atomic)
        }
    }
}
