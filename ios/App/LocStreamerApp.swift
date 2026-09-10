import SwiftUI

@main
struct LocStreamerApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            RootView(model: model)
        }
    }
}

/// Holds the session and starts streaming immediately on launch — including
/// the silent background relaunches iOS performs after a significant
/// location change — so recording never depends on the UI being shown.
@MainActor
@Observable
final class AppModel {
    var session: Session?
    let streamer = LocationStreamer()

    init() {
        session = Session.restore()
        if let session { streamer.start(session: session) }
    }

    func signedIn(_ session: Session) {
        session.persist()
        self.session = session
        streamer.start(session: session)
    }

    func signOut() {
        streamer.stop()
        Session.clear()
        session = nil
    }
}

struct RootView: View {
    @Bindable var model: AppModel

    var body: some View {
        if let session = model.session {
            TrackerView(session: session, streamer: model.streamer, signOut: model.signOut)
        } else {
            SignInView { model.signedIn($0) }
        }
    }
}
