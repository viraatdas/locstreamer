import Foundation

enum Config {
    /// The locstreamer API (Vercel). Change here if the deployment moves.
    static let apiBaseURL = URL(string: "https://locstreamer.vercel.app")!

    /// Upload cadence: whichever comes first.
    static let uploadInterval: TimeInterval = 60
    static let uploadBatchSize = 25

    /// While standing still Core Location goes quiet; this re-records the
    /// last known position so the day's trail has no gaps.
    static let heartbeatInterval: TimeInterval = 300
}
