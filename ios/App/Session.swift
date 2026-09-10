import Foundation

/// The signed-in device: a phone number and the bearer token the server
/// issued for it. Persisted in the keychain so it survives relaunches.
struct Session: Codable, Sendable {
    var phone: String
    var token: String

    private static let account = "session"

    static func restore() -> Session? {
        guard let data = KeychainStore.load(account: account) else { return nil }
        return try? JSONDecoder().decode(Session.self, from: data)
    }

    func persist() {
        guard let data = try? JSONEncoder().encode(self) else { return }
        KeychainStore.save(data, account: Self.account)
    }

    static func clear() {
        KeychainStore.delete(account: account)
    }
}
