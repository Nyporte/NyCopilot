import AppKit
@preconcurrency import ScreenCaptureKit

/// Every live screen stream NyCopilot runs (scrolling capture, GIF recording) starts and stops here,
/// so each has a delegate, each failure is noted, and a stream macOS won't stop is caught.
///
/// macOS's capture service has a flaw: when it frees space for a nearly full disk, it stops every
/// app's streams and leaves each app's connection broken. Streams the app starts afterwards still
/// run, but the service keeps no record of them, so they can't be stopped — not even by quitting
/// the app — and keep the screen-recording indicator on. Only restarting the service ends them, and
/// it gives NyCopilot a working connection again, so a stop that fails that way restarts it at once.
/// `onStuck` says so only if the restart failed; Settings → General can try again.
@MainActor
final class CaptureStreams {
    static let shared = CaptureStreams()

    /// A stop failed and restarting the service didn't help: macOS kept the stream running.
    var onStuck: (() -> Void)?
    /// Restarts macOS's capture service; replaceable in tests.
    var restartService: @Sendable () -> Bool = { CaptureStreams.restartCaptureService() }
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
            await stopFailed(name, error)
        }
    }

    /// attemptToStopStreamState: the service lost track of a stream it's still running, and of any
    /// it will start for NyCopilot. Restarting it ends the stream and mends the connection.
    func stopFailed(_ name: String, _ error: Error) async {
        let code = (error as NSError).code
        Diagnostics.note("capture", "\(name) didn’t stop: \(code) \(error.localizedDescription)")
        guard code == -3808 else { return }
        let restart = restartService
        let restarted = await Task.detached { restart() }.value
        if !restarted { onStuck?() }
    }

    /// Restarts macOS's capture service, which ends every stream it was stuck running; macOS
    /// starts it again on its own when something next captures.
    nonisolated static func restartCaptureService() -> Bool {
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
