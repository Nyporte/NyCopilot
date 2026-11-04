import AppKit
import ApplicationServices
import ServiceManagement

/// Accessibility: to find the focused field and paste into it, read what's selected, and find and
/// move other apps' windows. One of the two permissions NyCopilot asks for; see ScreenRecording.
enum Accessibility {
    static var isTrusted: Bool { AXIsProcessTrusted() }

    /// Show the system prompt (which adds NyCopilot to the list) and open the matching Settings pane.
    static func requestAccess() {
        _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }
}

/// Screen Recording: to capture the screen, record GIFs, and translate what's on screen.
enum ScreenRecording {
    static var isGranted: Bool { CGPreflightScreenCaptureAccess() }

    /// Shows the system prompt the first time; afterwards macOS only offers System Settings.
    static func requestAccess() {
        if !CGRequestScreenCaptureAccess() {
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
        }
    }
}

/// Login items through ServiceManagement; macOS may ask the user to approve in System Settings.
enum LaunchAtLogin {
    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }
    static var needsApproval: Bool { SMAppService.mainApp.status == .requiresApproval }

    static func set(_ enabled: Bool) throws {
        if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
    }
}
