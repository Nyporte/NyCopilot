import AppKit

/// One toolbar tab in Settings. Subclasses return their sections from `makeSections()`.
@MainActor
class SettingsPane: NSViewController {
    let paneID: String
    let paneTitle: String
    let symbolName: String

    init(id: String, title: String, symbol: String) {
        paneID = id
        paneTitle = title
        symbolName = symbol
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("Use init(id:title:symbol:)") }

    func makeSections() -> [NSView] { [] }

    /// Refresh live state (permissions, saved keys) each time the pane is shown.
    func paneWillAppear() {}

    override func loadView() {
        let stack = Design.vstack(makeSections(), spacing: Design.sectionSpacing)
        stack.translatesAutoresizingMaskIntoConstraints = false
        let container = NSView()
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            container.widthAnchor.constraint(equalToConstant: Design.paneWidth),
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: Design.panePadding),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -Design.panePadding),
            stack.topAnchor.constraint(equalTo: container.topAnchor, constant: 20),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -Design.panePadding)
        ])
        for section in stack.arrangedSubviews {
            section.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        view = container
    }
}

/// A macOS-style preferences window: icon tabs in the toolbar, one pane at a time, sized to fit.
@MainActor
final class SettingsWindow: NSWindowController, NSToolbarDelegate, NSWindowDelegate {
    private let panes: [SettingsPane]
    private var current: SettingsPane?

    init(panes: [SettingsPane]) {
        self.panes = panes
        let window = SettingsPanel(contentRect: NSRect(x: 0, y: 0, width: Design.paneWidth, height: 400),
                                   styleMask: [.titled, .closable], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.toolbarStyle = .preference
        window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        super.init(window: window)
        window.delegate = self
        let toolbar = NSToolbar(identifier: "NyCopilotSettings")
        toolbar.delegate = self
        toolbar.displayMode = .iconAndLabel
        toolbar.allowsUserCustomization = false
        window.toolbar = toolbar
    }

    required init?(coder: NSCoder) { fatalError("Use init(panes:)") }

    /// Open on a specific pane, or keep whichever pane the user last viewed.
    func present(pane id: String? = nil) {
        let target = panes.first(where: { $0.paneID == id }) ?? current ?? panes[0]
        select(target, animated: window?.isVisible == true)
        if window?.isVisible != true { window?.center() }
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }

    private func select(_ pane: SettingsPane, animated: Bool) {
        guard let window else { return }
        window.toolbar?.selectedItemIdentifier = .init(pane.paneID)
        window.title = pane.paneTitle
        _ = pane.view // Build the controls before refreshing them.
        pane.paneWillAppear()
        guard pane !== current else { return }
        current = pane
        // Swap content and resize around the fixed top edge, as System Settings–era panes do.
        let size = pane.view.fittingSize
        let contentFrame = window.frameRect(forContentRect: NSRect(origin: .zero, size: size))
        var frame = window.frame
        frame.origin.y += frame.height - contentFrame.height
        frame.size = contentFrame.size
        window.contentViewController = nil
        window.contentView = NSView()
        window.setFrame(frame, display: true, animate: animated)
        window.contentViewController = pane
    }

    @objc private func toolbarSelect(_ sender: NSToolbarItem) {
        if let pane = panes.first(where: { $0.paneID == sender.itemIdentifier.rawValue }) { select(pane, animated: true) }
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { panes.map { .init($0.paneID) } }
    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { panes.map { .init($0.paneID) } }
    func toolbarSelectableItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { panes.map { .init($0.paneID) } }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier identifier: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        guard let pane = panes.first(where: { $0.paneID == identifier.rawValue }) else { return nil }
        let item = NSToolbarItem(itemIdentifier: identifier)
        item.label = pane.paneTitle
        item.image = NSImage(systemSymbolName: pane.symbolName, accessibilityDescription: pane.paneTitle)
        item.target = self
        item.action = #selector(toolbarSelect(_:))
        return item
    }

    /// Commit any field still being edited, so closing the window never discards a typed value.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        sender.makeFirstResponder(nil)
        return true
    }
}

/// Escape closes Settings like a sheet, and ⌘W works without a document.
private final class SettingsPanel: NSWindow {
    override func cancelOperation(_ sender: Any?) { performClose(sender) }
}
