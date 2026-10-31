import AppKit

extension NSApplication {
    /// Brings NyCopilot forward for a window that needs it (Settings, History, the inbox, a save
    /// panel). Quick panels never call this: they take keys without activating (see FloatingPanel).
    ///
    /// This is the one place activation is requested, and it asks the old way on purpose: macOS 14's
    /// cooperative `activate()` may decline a request that comes from a global shortcut pressed
    /// while another app is in front — exactly how NyCopilot is used.
    func bringForward() {
        activate(ignoringOtherApps: true)
    }
}

extension NSRunningApplication {
    /// Gives this app the focus, then runs `then` once macOS reports it active — or after half a
    /// second if it never does (the app declined, or quit), so what waits on it can't hang.
    @MainActor
    func activate(then: @escaping () -> Void) {
        guard !isTerminated, !isActive else { then(); return }
        ActivationWait(then: then).start(self)
    }
}

@MainActor
private final class ActivationWait {
    private var then: (() -> Void)?
    private var observer: NSObjectProtocol?

    init(then: @escaping () -> Void) { self.then = then }

    func start(_ app: NSRunningApplication) {
        let pid = app.processIdentifier
        observer = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification,
                                                                     object: nil, queue: .main) { [self] note in
            guard (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.processIdentifier == pid else { return }
            MainActor.assumeIsolated { finish() }
        }
        app.activate(options: [])
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [self] in MainActor.assumeIsolated { finish() } }
    }

    private func finish() {
        guard let then else { return }
        self.then = nil
        if let observer { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        then()
    }
}
