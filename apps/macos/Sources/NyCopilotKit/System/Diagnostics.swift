import AppKit
import os

/// What NyCopilot did lately — which fields it found, where it pasted, which services failed — so
/// a problem can be explained, and reported in one click. Kept in memory only, never with any of
/// your text: app names, roles, and error codes.
enum Diagnostics {
    private static let lock = NSLock()
    private static var events: [String] = []
    private static let limit = 300
    private static let log = Logger(subsystem: "dev.nycopilot.NyCopilot", category: "diagnostics")
    private static let clock: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter
    }()

    /// One event under `area` (paste, translate, capture…); safe from any thread.
    static func note(_ area: String, _ message: String) {
        log.notice("\(area, privacy: .public): \(message, privacy: .public)")
        lock.lock()
        defer { lock.unlock() }
        events.append("\(clock.string(from: Date())) [\(area)] \(message)")
        if events.count > limit { events.removeFirst(events.count - limit) }
    }

    /// The version, macOS, permissions, and recent events, ready to paste into a bug report.
    static func report() -> String {
        let info = Bundle.main.infoDictionary
        let version = "\(info?["CFBundleShortVersionString"] as? String ?? "?") (\(info?["CFBundleVersion"] as? String ?? "?"))"
        let recent: [String] = {
            lock.lock()
            defer { lock.unlock() }
            return events
        }()
        return """
            NyCopilot \(version)
            macOS \(ProcessInfo.processInfo.operatingSystemVersionString)
            Accessibility: \(AXIsProcessTrusted() ? "allowed" : "not allowed")
            Screen Recording: \(CGPreflightScreenCaptureAccess() ? "allowed" : "not allowed")

            Recent activity (\(recent.count)):
            \(recent.isEmpty ? "(none)" : recent.joined(separator: "\n"))
            """
    }
}
