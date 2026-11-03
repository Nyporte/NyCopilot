import CNyCore
import Foundation

/// The Swift face of the shared Rust core. Every module's data, settings, and model access go
/// through `call`, using the same JSON method protocol every other client and the server speak.
final class NyCore: @unchecked Sendable {
    private let handle: OpaquePointer
    /// Settings as last read: reading one is a JSON round trip into SQLite, and menus, captures,
    /// and panels read them all the time. Dropped on every change the core reports and every write.
    private let settingsCache = SettingsCache()
    private let events: CoreEvents

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
        events = CoreEvents(settings: settingsCache)
        // The core holds the receiver unretained; `deinit` closes the core before it goes.
        let context = Unmanaged.passUnretained(events).toOpaque()
        var error: UnsafeMutablePointer<CChar>?
        let opened = String(decoding: config, as: UTF8.self).withCString { ny_open($0, nyCoreEvent, context, &error) }
        guard let opened else {
            defer { ny_string_free(error) }
            throw Self.decodeFailure(error.map { String(cString: $0) }) ?? Failure(code: "open", message: "NyCopilot couldn’t open its data.", status: nil)
        }
        handle = opened
    }

    deinit { ny_close(handle) }

    /// Calls `handler` on the main thread with every event this core reports, until the returned
    /// observation is cancelled or let go.
    func observe(_ handler: @escaping @MainActor (CoreEvent) -> Void) -> CoreObservation { events.add(handler) }

    /// Drops one cached setting, or all of them.
    func forgetSetting(_ key: String?) { settingsCache.forget(key) }

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
        if let cached = settingsCache[key] { return cached as? T ?? fallback }
        guard let value = try? call(.settingsGet, ["key": key]) else { return fallback }
        settingsCache[key] = value
        return value as? T ?? fallback
    }

    func setSetting(_ key: String, _ value: Any) throws {
        defer { settingsCache.forget(key) }
        try call(.settingsSet, ["key": key, "value": value])
    }

    private static func decodeFailure(_ text: String?) -> Failure? {
        guard let text, let data = text.data(using: .utf8),
              let envelope = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let error = envelope["error"], let errorData = try? JSONSerialization.data(withJSONObject: error) else { return nil }
        return try? JSONDecoder().decode(Failure.self, from: errorData)
    }
}

/// Something the core reports as it happens (spec/protocol.md, Events), decoded once on arrival.
enum CoreEvent: Decodable, Sendable, Equatable {
    /// A record inserted, updated, or deleted (`id`), or a whole collection cleared or pruned.
    case recordsChanged(collection: String, id: String?, change: String)
    case settingsChanged(key: String)
    /// A streamed Ask AI answer, all of it so far.
    case askDelta(requestID: String, text: String)
    /// A kind this client doesn't know.
    case unknown(type: String)

    /// The collection a `records.changed` is about.
    var changedCollection: String? {
        if case .recordsChanged(let collection, _, _) = self { collection } else { nil }
    }

    /// The key a `settings.changed` is about.
    var changedSetting: String? {
        if case .settingsChanged(let key) = self { key } else { nil }
    }

    private enum Key: String, CodingKey { case type, collection, id, change, key, text, requestID = "request_id" }

    init(from decoder: Decoder) throws {
        let event = try decoder.container(keyedBy: Key.self)
        let type = try event.decode(String.self, forKey: .type)
        switch type {
        case "records.changed":
            self = .recordsChanged(collection: try event.decode(String.self, forKey: .collection),
                                   id: try event.decodeIfPresent(String.self, forKey: .id),
                                   change: try event.decode(String.self, forKey: .change))
        case "settings.changed":
            self = .settingsChanged(key: try event.decode(String.self, forKey: .key))
        case "ask.delta":
            self = .askDelta(requestID: try event.decode(String.self, forKey: .requestID), text: try event.decode(String.self, forKey: .text))
        default:
            self = .unknown(type: type)
        }
    }
}

/// A running `NyCore.observe`: its handler is called until this is cancelled or let go.
final class CoreObservation: Sendable {
    private let stop: @Sendable () -> Void

    fileprivate init(stop: @escaping @Sendable () -> Void) { self.stop = stop }

    func cancel() { stop() }

    deinit { stop() }
}

/// Settings as last read, from any thread.
private final class SettingsCache: @unchecked Sendable {
    private let lock = NSLock()
    /// Guarded by `lock`.
    private var values: [String: Any] = [:]

    subscript(key: String) -> Any? {
        get { lock.lock(); defer { lock.unlock() }; return values[key] }
        set { lock.lock(); defer { lock.unlock() }; values[key] = newValue }
    }

    func forget(_ key: String?) {
        lock.lock(); defer { lock.unlock() }
        if let key { values[key] = nil } else { values.removeAll() }
    }
}

/// Who hears a core's events. They arrive on whichever thread made the change: a changed setting
/// leaves the cache at once, and handlers hear of it on the main thread.
private final class CoreEvents: @unchecked Sendable {
    private let settings: SettingsCache
    private let lock = NSLock()
    /// Guarded by `lock`; called only on the main thread.
    private var handlers: [UUID: @MainActor (CoreEvent) -> Void] = [:]

    init(settings: SettingsCache) { self.settings = settings }

    func add(_ handler: @escaping @MainActor (CoreEvent) -> Void) -> CoreObservation {
        let id = UUID()
        lock.lock(); handlers[id] = handler; lock.unlock()
        return CoreObservation { [weak self] in self?.remove(id) }
    }

    private func remove(_ id: UUID) {
        lock.lock(); defer { lock.unlock() }
        handlers[id] = nil
    }

    private func handler(_ id: UUID) -> (@MainActor (CoreEvent) -> Void)? {
        lock.lock(); defer { lock.unlock() }
        return handlers[id]
    }

    func deliver(_ json: Data) {
        guard let event = try? JSONDecoder().decode(CoreEvent.self, from: json) else { return }
        if case .settingsChanged(let key) = event { settings.forget(key) }
        DispatchQueue.main.async { [self] in
            MainActor.assumeIsolated {
                lock.lock(); let ids = Array(handlers.keys); lock.unlock()
                // One handler may cancel another; a cancelled one hears nothing more.
                for id in ids { handler(id)?(event) }
            }
        }
    }
}

private func nyCoreEvent(_ json: UnsafePointer<CChar>?, _ context: UnsafeMutableRawPointer?) {
    guard let json, let context else { return }
    Unmanaged<CoreEvents>.fromOpaque(context).takeUnretainedValue().deliver(Data(bytes: json, count: strlen(json)))
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
