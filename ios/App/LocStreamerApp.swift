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
        if let session {
            streamer.start(session: session)
        } else if streamer.isAuthorized {
            // Reboot-before-unlock case: location is already authorized but the
            // keychain session couldn't be read yet. Resume recording now (SLC
            // must be re-registered in this process); flush() retries
            // Session.restore() and uploads once unlock happens. On a FRESH
            // install we do NOT start here — that would fire an uncontextualized
            // permission prompt and record points for nobody before sign-in.
            streamer.startRecording()
        }
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

    /// Deletes all server-side location history for the signed-in phone, then
    /// signs out and wipes the local buffer. Apple guideline 5.1.1(v).
    func deleteAccount() async throws {
        if let session {
            try await API().deleteAllData(token: session.token)
        }
        signOut()
    }
}

struct RootView: View {
    @Bindable var model: AppModel

    var body: some View {
        if let session = model.session {
            TrackerView(
                session: session,
                streamer: model.streamer,
                signOut: model.signOut,
                deleteAccount: model.deleteAccount
            )
        } else {
            SignInView { model.signedIn($0) }
        }
    }
}
