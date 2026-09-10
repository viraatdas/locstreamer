import Foundation

/// Plain URLSession client for the locstreamer server. Phone OTP is the same
/// shape as Manas: request a code, redeem it, keep the bearer token.
struct API: Sendable {
    var baseURL: URL = Config.apiBaseURL

    enum APIError: LocalizedError {
        case server(String)
        var errorDescription: String? {
            switch self {
            case .server(let message): message
            }
        }
    }

    func requestCode(phone: String) async throws -> String {
        let body = try await post("api/otp/send", json: ["phone": phone])
        guard let id = body["method_id"] as? String else {
            throw APIError.server("Couldn't send the code.")
        }
        return id
    }

    func verifyCode(phone: String, methodID: String, code: String) async throws -> Session {
        let body = try await post(
            "api/otp/verify",
            json: ["phone": phone, "method_id": methodID, "code": code]
        )
        guard let token = body["token"] as? String, let verified = body["phone"] as? String else {
            throw APIError.server("That code didn't match.")
        }
        return Session(phone: verified, token: token)
    }

    func upload(_ points: [LocationPoint], token: String) async throws {
        let payload = points.map { p -> [String: Any] in
            var dict: [String: Any] = ["ts": p.ts, "lat": p.lat, "lon": p.lon]
            if let acc = p.acc { dict["acc"] = acc }
            if let spd = p.spd { dict["spd"] = spd }
            return dict
        }
        _ = try await post("api/locations", json: ["points": payload], bearer: token)
    }

    private func post(_ path: String, json: [String: Any], bearer: String? = nil) async throws -> [String: Any] {
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let bearer { request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization") }
        request.httpBody = try JSONSerialization.data(withJSONObject: json)
        request.timeoutInterval = 30
        let (data, response) = try await URLSession.shared.data(for: request)
        let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            let message = (object["error"] as? String) ?? "Request failed (\(http.statusCode))."
            throw APIError.server(message)
        }
        return object
    }
}
