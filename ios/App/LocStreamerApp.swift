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
        // Always start recording, even if the session couldn't be read yet
        // (reboot before first unlock). The streamer retries Session.restore()
        // in flush() and uploads once a session is available.
        streamer.startRecording()
        if let session { streamer.attach(session: session) }
        #if DEBUG
        // Scripted sign-in for simulator verification (scripts/ios-run-sim.sh):
        //   -probePhone +15555550100 -probeCode 123456
        // Debug builds only; the App Store binary has no such path.
        if session == nil {
            let defaults = UserDefaults.standard
            if let phone = defaults.string(forKey: "probePhone"), let code = defaults.string(forKey: "probeCode") {
                Task { @MainActor in
                    let api = API()
                    do {
                        let methodID = try await api.requestCode(phone: phone)
                        signedIn(try await api.verifyCode(phone: phone, methodID: methodID, code: code))
                    } catch {
                        print("probe sign-in failed: \(error.localizedDescription)")
                    }
                }
            }
        }
        #endif
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
