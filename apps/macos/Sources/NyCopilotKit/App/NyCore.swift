import CNyCore
import Foundation

/// The Swift face of the shared Rust core. Every module's data, settings, and model access go
/// through `call`, using the same JSON method protocol every other client and the server speak.
final class NyCore: @unchecked Sendable {
    /// Posted on the main thread for every core event; `userInfo["event"]` holds the decoded JSON.
    static let eventNotification = Notification.Name("NyCopilot.CoreEvent")

    private let handle: OpaquePointer
    /// Settings as last read: reading one is a JSON round trip into SQLite, and menus, captures,
    /// and panels read them all the time. Dropped on every change the core reports and every write.
    private let cacheLock = NSLock()
    private var settingsCache: [String: Any] = [:]
    private var observer: NSObjectProtocol?

    /// The error envelope from the core: a stable `code` plus an English message, shown in the
    /// interface language.
    struct Failure: LocalizedError, Decodable {
        let code: String
        let message: String
        let status: Int?
        var errorDescription: String? { CoreText.localized(message) }
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
        observer = NotificationCenter.default.addObserver(forName: Self.eventNotification, object: nil, queue: nil) { [weak self] note in
            guard let event = note.userInfo?["event"] as? [String: Any], event["type"] as? String == "settings.changed" else { return }
            self?.forget(event["key"] as? String)
        }
    }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        ny_close(handle)
    }

    /// Drops one cached setting, or all of them.
    func forgetSetting(_ key: String?) { forget(key) }

    private func forget(_ key: String?) {
        cacheLock.lock(); defer { cacheLock.unlock() }
        if let key { settingsCache[key] = nil } else { settingsCache.removeAll() }
    }

    /// Synchronous call; fine for settings and records. Use `perform` for model-backed methods.
    @discardableResult
    func call(_ method: CoreMethod, _ params: [String: Any] = [:]) throws -> Any { try call(name: method.rawValue, params) }

    private func call(name method: String, _ params: [String: Any]) throws -> Any {
        let body = try JSONSerialization.data(withJSONObject: params)
        guard let raw = method.withCString({ name in
            String(decoding: body, as: UTF8.self).withCString { ny_call(handle, name, $0) }
        }) else { throw Failure(code: "internal", message: "The core returned no result.", status: nil) }
        defer { ny_string_free(raw) }
        let envelope = try JSONSerialization.jsonObject(with: Data(bytes: raw, count: strlen(raw)), options: [.fragmentsAllowed]) as? [String: Any]
        if let error = envelope?["error"] {
            let data = try JSONSerialization.data(withJSONObject: error)
            let failure = try JSONDecoder().decode(Failure.self, from: data)
            // Many callers can only shrug (`try?`); the failure is still on record for a bug report.
            // Cancellations are expected, not failures.
            if failure.code != "cancelled" { Diagnostics.note("core", "\(method) failed: \(failure.code)") }
            throw failure
        }
        return envelope?["ok"] ?? NSNull()
    }

    /// Decode a result into a Codable type (snake_case keys become camelCase).
    func call<T: Decodable>(_ method: CoreMethod, _ params: [String: Any] = [:], as type: T.Type) throws -> T {
        let value = try call(method, params)
        let data = try JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed])
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(T.self, from: data)
    }

    /// Run a blocking call (such as a model request) off the main thread. The parameters are
    /// encoded here, so nothing mutable crosses to the other thread.
    @MainActor
    func perform<T: Decodable & Sendable>(_ method: CoreMethod, _ params: [String: Any] = [:], as type: T.Type) async throws -> T {
        let body = try JSONSerialization.data(withJSONObject: params)
        return try await Task.detached(priority: .userInitiated) { [self] in
            let decoded = try JSONSerialization.jsonObject(with: body) as? [String: Any] ?? [:]
            return try call(method, decoded, as: type)
        }.value
    }

    func setting<T>(_ key: String, default fallback: T) -> T {
        cacheLock.lock()
        let cached = settingsCache[key]
        cacheLock.unlock()
        if let cached { return cached as? T ?? fallback }
        guard let value = try? call(.settingsGet, ["key": key]) else { return fallback }
        cacheLock.lock(); settingsCache[key] = value; cacheLock.unlock()
        return value as? T ?? fallback
    }

    func setSetting(_ key: String, _ value: Any) throws {
        defer { forget(key) }
        try call(.settingsSet, ["key": key, "value": value])
    }

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
    // JSON values are immutable once parsed.
    struct Payload: @unchecked Sendable { let event: [String: Any] }
    let payload = Payload(event: event)
    DispatchQueue.main.async {
        NotificationCenter.default.post(name: NyCore.eventNotification, object: nil, userInfo: ["event": payload.event])
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

extension CoreRecord: Sendable where Data: Sendable {}
extension CorePage: Sendable where Data: Sendable {}
