import SwiftUI

/// Phone number in, one-time code back, session out. No web view anywhere.
struct SignInView: View {
    var onSignedIn: (Session) -> Void

    @State private var phone = "+1"
    @State private var code = ""
    @State private var methodID: String?
    @State private var busy = false
    @State private var error: String?
    private let api = API()

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("+1 415 555 1234", text: $phone)
                        .keyboardType(.phonePad)
                        .textContentType(.telephoneNumber)
                        .disabled(methodID != nil)
                } header: {
                    Text("Phone number")
                } footer: {
                    Text("Include the country code. A code is sent by SMS.")
                }

                if methodID != nil {
                    Section("Code") {
                        TextField("123456", text: $code)
                            .keyboardType(.numberPad)
                            .textContentType(.oneTimeCode)
                    }
                }

                if let error {
                    Section { Text(error).foregroundStyle(.red) }
                }

                Section {
                    if methodID == nil {
                        Button(action: sendCode) {
                            if busy { ProgressView() } else { Text("Send code") }
                        }
                        .disabled(busy || normalizedPhone == nil)
                    } else {
                        Button(action: verify) {
                            if busy { ProgressView() } else { Text("Sign in") }
                        }
                        .disabled(busy || code.trimmingCharacters(in: .whitespaces).count < 4)
                        Button("Use a different number") {
                            methodID = nil
                            code = ""
                            error = nil
                        }
                    }
                }
            }
            .navigationTitle("LocStreamer")
        }
    }

    /// "+" plus digits; nil when there aren't enough digits to be a number.
    private var normalizedPhone: String? {
        let digits = phone.filter(\.isNumber)
        return digits.count >= 7 ? "+\(digits)" : nil
    }

    private func sendCode() {
        guard let number = normalizedPhone else { return }
        busy = true
        error = nil
        Task {
            defer { busy = false }
            do { methodID = try await api.requestCode(phone: number) }
            catch { self.error = error.localizedDescription }
        }
    }

    private func verify() {
        guard let number = normalizedPhone, let methodID else { return }
        busy = true
        error = nil
        Task {
            defer { busy = false }
            do {
                let session = try await api.verifyCode(
                    phone: number, methodID: methodID, code: code.trimmingCharacters(in: .whitespaces)
                )
                onSignedIn(session)
            } catch { self.error = error.localizedDescription }
        }
    }
}
