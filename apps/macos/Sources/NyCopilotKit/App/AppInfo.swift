import AppKit

extension Bundle {
    /// "0.5.0 (42)": the version and the build, as bug reports quote them.
    var versionDescription: String {
        "\(infoDictionary?["CFBundleShortVersionString"] as? String ?? "?") (\(infoDictionary?["CFBundleVersion"] as? String ?? "?"))"
    }
}

extension Diagnostics {
    /// The report on the clipboard, to paste into a bug report.
    static func copyReport() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(report(), forType: .string)
    }
}
