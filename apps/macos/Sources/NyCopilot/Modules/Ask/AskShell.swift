import AppKit
import MacPlatform

/// macOS half of Ask AI: the shortcut asks about what's selected in any app (or opens a blank
/// question), and other modules hand over their things — a screenshot, an inbox note, a pin —
/// through `CopilotServices.askAI`. The answer can be copied, kept in the inbox, or, for a selection
/// in a field you can type in, put in its place.
@MainActor
final class AskShell: ModuleShell {
    let id = "ask"
    let title = "Ask AI"
    let symbolName = "sparkles"

    enum Action {
        static let open = "ask.open"
    }

    private let services: CopilotServices
    private let panel = AskPanel()
    private var material = AskMaterial()
    /// A screenshot as the core takes it: a PNG (base64) and the text read from it, prepared once.
    private var prepared: Task<(image: String?, text: String), Never>?
    private var requestID: String?

    init(services: CopilotServices) {
        self.services = services
        services.askAI = { [weak self] material in self?.present(material) }
        panel.onAsk = { [weak self] action, question, turns in
            guard let self else { throw CancellationError() }
            return try await ask(action: action, question: question, turns: turns)
        }
        panel.onCancel = { [weak self] in
            guard let self, let requestID else { return }
            services.core.cancel(requestID: requestID)
            self.requestID = nil
        }
        panel.onKeep = { [weak self] answer in
            guard let self else { return }
            services.sendToInbox(answer, nil, material.app)
        }
        panel.onReplace = { [weak self] answer in self?.replace(with: answer) }
    }

    var hotKeyActions: [HotKeyCenter.Action] {
        [.init(id: Action.open, title: "Ask about the selection, or ask anything",
               defaultCombination: .init(keyCode: 0, modifiers: HotKeyCombination.option | HotKeyCombination.command), // ⌥⌘A
               handler: { [weak self] in self?.open() })]
    }

    func menuItems() -> [NSMenuItem] {
        [services.menuItem("Ask AI…", symbol: "sparkles", hotKey: Action.open, target: self, action: #selector(openFromMenu))]
    }

    func makeSettingsPane() -> SettingsPane? { AskPane(services: services) }

    func shutdown() { panel.close() }

    @objc private func openFromMenu() { open() }

    /// The selection in the app in front, with where it is; a selection in a field you can type in
    /// can be replaced by a rewrite.
    private func open() {
        if panel.isVisible { panel.close(); return }
        let app = NSWorkspace.shared.frontmostApplication
        let foreign = app.flatMap { $0.processIdentifier == ProcessInfo.processInfo.processIdentifier ? nil : $0 }
        Task {
            var material = AskMaterial(source: await SourceContext.of(foreign), app: foreign)
            if let foreign, Accessibility.isTrusted, let selected = await InputTarget.selectedText(pid: foreign.processIdentifier) {
                material.text = selected.text
                material.anchor = selected.bounds.map(Self.appKitRect)
                if let target = try? await InputTarget.capture(pid: foreign.processIdentifier), target.hasSelection {
                    material.replaceable = target
                }
            }
            present(material)
        }
    }

    private func present(_ material: AskMaterial) {
        self.material = material
        prepared = material.image.map { image in Task { await Self.prepare(image) } }
        panel.present(material)
    }

    private func ask(action: String, question: String, turns: [[String: String]]) async throws -> String {
        struct Answer: Decodable { let text: String }
        var params: [String: Any] = ["action": action, "text": material.text, "question": question, "turns": turns,
                                     "language": services.core.readingLanguage, "api_key": try KeychainStore.read()]
        if let screenshot = await prepared?.value {
            if let image = screenshot.image { params["image"] = image }
            params["text"] = screenshot.text
        }
        let id = UUID().uuidString
        requestID = id
        params["request_id"] = id
        defer { if requestID == id { requestID = nil } }
        do {
            return try await services.core.perform("ask.run", params, as: Answer.self).text
        } catch {
            Diagnostics.note("ask", "\(action) failed: \(error.localizedDescription)")
            throw error
        }
    }

    /// At most 2048 pixels on the long side — enough to read, small enough to send — and its text,
    /// read on this Mac, for models that take no images.
    private static func prepare(_ image: NSImage) async -> (image: String?, text: String) {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return (nil, "") }
        let lines = (try? await ScreenText.lines(in: cgImage, scale: 1)) ?? []
        let text = lines.map(\.text).joined(separator: "\n")
        let encoded = await Task.detached(priority: .userInitiated) { () -> String? in
            let longest = max(cgImage.width, cgImage.height)
            let factor = min(1, 2048 / Double(max(longest, 1)))
            let width = Int(Double(cgImage.width) * factor), height = Int(Double(cgImage.height) * factor)
            guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                          space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
            context.interpolationQuality = .high
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
            guard let scaled = context.makeImage(),
                  let png = NSBitmapImageRep(cgImage: scaled).representation(using: .png, properties: [:]) else { return nil }
            return png.base64EncodedString()
        }.value
        return (encoded, text)
    }

    /// The rewrite in place of the selection it came from; if the field moved on, onto the clipboard.
    private func replace(with answer: String) {
        guard let target = material.replaceable else { return }
        panel.close()
        Task {
            do {
                try await target.insert(answer, prepareForPaste: {})
            } catch {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(answer, forType: .string)
                services.toast.show("Copied the rewrite", detail: error.localizedDescription, style: .info)
            }
        }
    }

    /// AX (top-left) to AppKit (bottom-left) coordinates.
    static func appKitRect(_ rect: CGRect) -> NSRect {
        let top = NSScreen.screens.first?.frame.maxY ?? 0
        return NSRect(x: rect.minX, y: top - rect.maxY, width: rect.width, height: rect.height)
    }
}

/// Ask AI settings: the shortcut, and whether screenshots go to the model as images.
@MainActor
final class AskPane: SettingsPane {
    private let services: CopilotServices
    private let imagesSwitch = NSSwitch()
    private lazy var shortcuts = ShortcutEditor(services: services)

    init(services: CopilotServices) {
        self.services = services
        super.init(id: "ask", title: "Ask AI", symbol: "sparkles")
    }

    required init?(coder: NSCoder) { fatalError("Use init(services:)") }

    override func makeSections() -> [NSView] {
        imagesSwitch.target = self
        imagesSwitch.action = #selector(toggleImages)
        return [
            FormSection("Asking", footer: "Ask AI uses the model in Settings → Model. Select text anywhere and press the shortcut to explain, summarize, rewrite, or ask about it; in a screenshot, a pin, or the inbox, press A.", rows: [
                FormRow("Send screenshots as images", subtitle: "The model must accept images. Off sends only the text read from them, on this Mac.", accessory: imagesSwitch)
            ]),
            shortcuts.section("Shortcuts", footer: nil, actions: [AskShell.Action.open]),
            shortcuts.errorLabel
        ]
    }

    override func paneWillAppear() {
        imagesSwitch.state = services.core.setting(.askSendImages, default: true) ? .on : .off
        shortcuts.refresh()
    }

    @objc private func toggleImages() { try? services.core.setSetting(.askSendImages, imagesSwitch.state == .on) }
}
