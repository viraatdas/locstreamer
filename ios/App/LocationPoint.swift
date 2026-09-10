import CoreLocation
import Foundation

/// One recorded fix. `ts` is Unix epoch milliseconds, matching the server.
struct LocationPoint: Codable, Identifiable, Sendable {
    var ts: Int64
    var lat: Double
    var lon: Double
    var acc: Double?
    var spd: Double?

    var id: Int64 { ts }
    var date: Date { Date(timeIntervalSince1970: Double(ts) / 1000) }

    init(_ location: CLLocation, at date: Date? = nil) {
        ts = Int64(((date ?? location.timestamp).timeIntervalSince1970 * 1000).rounded())
        lat = location.coordinate.latitude
        lon = location.coordinate.longitude
        acc = location.horizontalAccuracy >= 0 ? location.horizontalAccuracy : nil
        spd = location.speed >= 0 ? location.speed : nil
    }
}
