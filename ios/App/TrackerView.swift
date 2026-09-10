import SwiftUI

/// Status plus the raw list of recent fixes. Deliberately no map.
struct TrackerView: View {
    let session: Session
    let streamer: LocationStreamer
    let signOut: () -> Void

    var body: some View {
        NavigationStack {
            List {
                Section("Status") {
                    LabeledContent("Phone", value: session.phone)
                    LabeledContent("Permission", value: permissionLabel)
                    LabeledContent("Recorded this run", value: "\(streamer.totalRecorded)")
                    LabeledContent("Waiting to upload", value: "\(streamer.pending)")
                    LabeledContent("Last upload", value: streamer.lastUpload.map { $0.formatted(date: .omitted, time: .standard) } ?? "never")
                    if let error = streamer.lastError {
                        Text(error).font(.footnote).foregroundStyle(.red)
                    }
                    if !streamer.hasAlwaysAuthorization {
                        Button("Allow location \"Always\"") {
                            if streamer.authorization == .denied || streamer.authorization == .restricted {
                                if let url = URL(string: UIApplication.openSettingsURLString) {
                                    UIApplication.shared.open(url)
                                }
                            } else {
                                streamer.requestAlways()
                            }
                        }
                    }
                    Button("Upload now") { Task { await streamer.flush() } }
                        .disabled(streamer.pending == 0)
                }

                Section("Recent points") {
                    if streamer.recent.isEmpty {
                        Text("Waiting for the first fix…").foregroundStyle(.secondary)
                    }
                    ForEach(streamer.recent) { point in
                        HStack {
                            Text(String(format: "%.5f, %.5f", point.lat, point.lon))
                                .font(.system(.body, design: .monospaced))
                            Spacer()
                            Text(point.date.formatted(date: .omitted, time: .standard))
                                .foregroundStyle(.secondary)
                                .font(.footnote)
                        }
                    }
                }
            }
            .navigationTitle("LocStreamer")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Sign out", role: .destructive, action: signOut)
                }
            }
        }
    }

    private var permissionLabel: String {
        switch streamer.authorization {
        case .authorizedAlways: "Always"
        case .authorizedWhenInUse: "While using (needs Always)"
        case .denied: "Denied"
        case .restricted: "Restricted"
        case .notDetermined: "Not asked yet"
        @unknown default: "Unknown"
        }
    }
}
