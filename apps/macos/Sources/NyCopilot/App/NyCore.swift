import CNyCore
import Foundation

/// The Swift face of the shared Rust core. Every module's data, settings, and model access go
/// through `call`, using the same JSON method protocol every other client and the server speak.
final class NyCore: @unchecked Sendable {
    /// Posted on the main thread for every core event; `userInfo["event"]` holds the decoded JSON.
    static let eventNotification = Notification.Name("NyCopilot.CoreEvent")

    private let handle: OpaquePointer

    /// The error envelope from the core: a stable `code` plus a message suitable for display.
    struct Failure: LocalizedError, Decodable {
        let code: String
        let message: String
        let status: Int?
        var errorDescription: String? { message }
    }

    init(dataDirectory: URL) throws {
        let config = try JSONSerialization.data(withJSONObject: ["data_dir": dataDirectory.path, "platform": "macos"])
        var error: UnsafeMutablePointer<CChar>?
        let opened = String(decoding: config, as: UTF8.self).withCString { ny_open($0, nyCoreEvent, nil, &error) }
        guard let opened else {
            defer { ny_string_free(error) }
            throw Self.decodeFailure(error.map { String(cString: $0) }) ?? Failure(code: "open", message: "NyCopilot couldn’t open its data.", status: nil)
        }
        handle = opened
    }

    deinit { ny_close(handle) }

    /// Synchronous call; fine for settings and records. Use `perform` for model-backed methods.
    @discardableResult
    func call(_ method: String, _ params: [String: Any] = [:]) throws -> Any {
        let body = try JSONSerialization.data(withJSONObject: params)
        guard let raw = method.withCString({ name in
            String(decoding: body, as: UTF8.self).withCString { ny_call(handle, name, $0) }
        }) else { throw Failure(code: "internal", message: "The core returned no result.", status: nil) }
        defer { ny_string_free(raw) }
        let envelope = try JSONSerialization.jsonObject(with: Data(bytes: raw, count: strlen(raw)), options: [.fragmentsAllowed]) as? [String: Any]
        if let error = envelope?["error"] {
            let data = try JSONSerialization.data(withJSONObject: error)
            throw try JSONDecoder().decode(Failure.self, from: data)
        }
        return envelope?["ok"] ?? NSNull()
    }

    /// Decode a result into a Codable type (snake_case keys become camelCase).
    func call<T: Decodable>(_ method: String, _ params: [String: Any] = [:], as type: T.Type) throws -> T {
        let value = try call(method, params)
        let data = try JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed])
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(T.self, from: data)
    }

    /// Run a blocking call (such as a model request) off the main thread.
    func perform<T: Decodable>(_ method: String, _ params: [String: Any] = [:], as type: T.Type) async throws -> T {
        try await Task.detached(priority: .userInitiated) { [self] in try call(method, params, as: type) }.value
    }

    func setting<T>(_ key: String, default fallback: T) -> T {
        (try? call("settings.get", ["key": key])) as? T ?? fallback
    }

    func setSetting(_ key: String, _ value: Any) throws { try call("settings.set", ["key": key, "value": value]) }

    private static func decodeFailure(_ text: String?) -> Failure? {
        guard let text, let data = text.data(using: .utf8),
              let envelope = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let error = envelope["error"], let errorData = try? JSONSerialization.data(withJSONObject: error) else { return nil }
        return try? JSONDecoder().decode(Failure.self, from: errorData)
    }
}

/// Events may arrive on any thread; republish them on the main thread for UI code.
private func nyCoreEvent(_ json: UnsafePointer<CChar>?, _ context: UnsafeMutableRawPointer?) {
    guard let json, let event = try? JSONSerialization.jsonObject(with: Data(bytes: json, count: strlen(json))) as? [String: Any] else { return }
    DispatchQueue.main.async {
        NotificationCenter.default.post(name: NyCore.eventNotification, object: nil, userInfo: ["event": event])
    }
}

/// A stored record as returned by `records.*` methods.
struct CoreRecord<Data: Decodable>: Decodable {
    let id: String
    let collection: String
    let data: Data
    let createdAt: Int64
}

struct CorePage<Data: Decodable>: Decodable {
    let records: [CoreRecord<Data>]
    let next: String?
}
