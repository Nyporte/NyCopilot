import AppKit
import ScreenCaptureKit

/// Every live screen stream NyCopilot runs (scrolling capture, GIF recording) starts and stops here,
/// so each has a delegate, each failure is noted, and a stream macOS won't stop is caught.
///
/// macOS's capture service has a flaw: when it purges (low disk space, memory pressure) it forgets
/// the streams it's running without stopping them. Such a stream can't be stopped any more — it
/// keeps the screen-recording indicator on and keeps capturing until the service restarts. When a
/// stop fails that way, `onStuck` says so; Settings → General can restart the service.
@MainActor
final class CaptureStreams {
    static let shared = CaptureStreams()

    /// A stop failed: macOS kept the stream running.
    var onStuck: (() -> Void)?
    private var live: [ObjectIdentifier: (name: String, watcher: Watcher)] = [:]

    /// Starts a stream with `output` on `queue`; `onEnded` runs if macOS ends it on its own.
    func start(_ name: String, filter: SCContentFilter, configuration: SCStreamConfiguration,
               output: SCStreamOutput, queue: DispatchQueue, onEnded: @escaping @MainActor () -> Void) async throws -> SCStream {
        let watcher = Watcher(name: name, onEnded: onEnded)
        let stream = SCStream(filter: filter, configuration: configuration, delegate: watcher)
        try stream.addStreamOutput(output, type: .screen, sampleHandlerQueue: queue)
        try await stream.startCapture()
        live[ObjectIdentifier(stream)] = (name, watcher)
        watcher.onGone = { [weak self, weak stream] in
            guard let stream else { return }
            self?.live[ObjectIdentifier(stream)] = nil
        }
        return stream
    }

    /// Stops `stream`. A stop macOS refuses because it no longer knows the stream is the flaw above.
    func stop(_ stream: SCStream) async {
        let name = live.removeValue(forKey: ObjectIdentifier(stream))?.name ?? "stream"
        do {
            try await stream.stopCapture()
        } catch {
            let code = (error as NSError).code
            Diagnostics.note("capture", "\(name) didn’t stop: \(code) \(error.localizedDescription)")
            // attemptToStopStreamState: the service lost track of a stream it's still running.
            if code == -3808 { onStuck?() }
        }
    }

    /// Restarts macOS's capture service, which ends every stream it was stuck running; macOS
    /// starts it again on its own when something next captures.
    static func restartCaptureService() -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
        process.arguments = ["-9", "replayd"]
        do { try process.run() } catch { return false }
        process.waitUntilExit()
        Diagnostics.note("capture", "restarted the screen capture service (\(process.terminationStatus))")
        return process.terminationStatus == 0
    }

    private final class Watcher: NSObject, SCStreamDelegate, @unchecked Sendable {
        let name: String
        let onEnded: @MainActor () -> Void
        var onGone: (@MainActor () -> Void)?

        init(name: String, onEnded: @escaping @MainActor () -> Void) {
            self.name = name
            self.onEnded = onEnded
        }

        func stream(_ stream: SCStream, didStopWithError error: Error) {
            Diagnostics.note("capture", "\(name) ended by macOS: \((error as NSError).code) \(error.localizedDescription)")
            DispatchQueue.main.async { [self] in
                MainActor.assumeIsolated {
                    onGone?()
                    onEnded()
                }
            }
        }
    }
}
