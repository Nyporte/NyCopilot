import AppKit
import SwiftUI
import Translation

/// macOS's own translation panel (macOS 14.4 and later), for when no translation service is set up:
/// translation works out of the box, on this Mac. It's the system's panel — the language is picked
/// there — and, for text you're writing, its "Replace with Translation" hands the result back to be
/// pasted like any other.
@MainActor
enum SystemTranslation {
    static var isAvailable: Bool {
        if #available(macOS 14.4, *) { return true }
        return false
    }

    /// A translation failed only because no service is set up, and macOS can translate it instead.
    static func standsIn(for error: Error) -> Bool {
        (error as? NyCore.Failure)?.code == "provider_not_configured" && isAvailable
    }

    private static var host: NSPanel?

    /// Shows the panel beside `anchor` (AppKit coordinates). With `replace`, the panel offers to
    /// replace the text and hands back the translation.
    static func present(_ text: String, near anchor: NSRect, replace: ((String) -> Void)? = nil) {
        guard #available(macOS 14.4, *) else { return }
        close()
        let panel = NSPanel(contentRect: anchor.insetBy(dx: min(0, anchor.width / 2 - 1), dy: min(0, anchor.height / 2 - 1)),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.float(at: .floating, shadow: false)
        panel.contentView = NSHostingView(rootView: Presenter(text: text, replace: replace.map { action in
            { translated in close(); action(translated) }
        }, closed: { close() }))
        host = panel
        // SwiftUI presents its panel from an active app.
        NSApp.bringForward()
        panel.orderFrontRegardless()
        panel.makeKey()
        Diagnostics.note("translate", "no service set up; opened macOS’s translation panel")
    }

    static func close() {
        host?.orderOut(nil)
        host = nil
    }
}

@available(macOS 14.4, *)
private struct Presenter: View {
    let text: String
    let replace: ((String) -> Void)?
    let closed: () -> Void
    @State private var shown = false

    var body: some View {
        Color.clear
            .translationPresentation(isPresented: $shown, text: text, arrowEdge: .bottom, replacementAction: replace)
            .onAppear { shown = true }
            .onChange(of: shown) { _, isShown in if !isShown { closed() } }
    }
}
