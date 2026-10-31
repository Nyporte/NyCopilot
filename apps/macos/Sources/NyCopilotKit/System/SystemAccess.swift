import AppKit
import ApplicationServices
import ServiceManagement

/// Accessibility is the one permission NyCopilot needs: to find the focused field and paste into it.
enum Accessibility {
    static var isTrusted: Bool { AXIsProcessTrusted() }

    /// Show the system prompt (which adds NyCopilot to the list) and open the matching Settings pane.
    static func requestAccess() {
        _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
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
