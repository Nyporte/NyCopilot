import AppKit
import MacPlatform

/// macOS half of Ask AI: the shortcut asks about what's selected in any app (or opens a blank
/// question), and other modules hand over their things — a screenshot, an inbox note, a pin —
/// through `CopilotServices.askAI`. The answer can be copied, kept in the inbox, or, for a selection
/// in a field you can type in, put in its place.
@MainActor
final class AskShell: ModuleShell {
    let id = "ask"
    let title = L("Ask AI")
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
        panel.onPin = { [weak services] answer in services?.pinOnScreen(answer, nil) }
    }

    var hotKeyActions: [HotKeyCenter.Action] {
        [.init(id: Action.open, title: L("Ask about the selection, or ask anything"),
               defaultCombination: .init(keyCode: 118, modifiers: 0), // F4
               handler: { [weak self] in self?.open() })]
    }

    func menuItems() -> [NSMenuItem] {
        [services.menuItem(L("Ask AI…"), symbol: "sparkles", hotKey: Action.open, target: self, action: #selector(openFromMenu))]
    }

    /// Its options live in AI & Engines, with the model it uses.
    func makeSettingsPane() -> SettingsPane? { nil }

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
                material.anchor = selected.bounds.map(ScreenGeometry.appKit)
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

    /// `ask.run`'s parameters, streamed.
    private struct Request: Encodable {
        let action: String
        var text: String
        let question: String
        let turns: [AskTurn]
        let language: String
        let apiKey: String
        var image: String?
        var requestID = ""
        let stream = true

        enum CodingKeys: String, CodingKey {
            case action, text, question, turns, language, image, stream, apiKey = "api_key", requestID = "request_id"
        }
    }

    private func ask(action: String, question: String, turns: [AskTurn]) async throws -> String {
        struct Answer: Decodable { let text: String }
        var request = Request(action: action, text: material.text, question: question, turns: turns,
                              language: services.core.readingLanguage, apiKey: try KeychainStore.read())
        if let screenshot = await prepared?.value {
            request.image = screenshot.image
            request.text = screenshot.text
        }
        let id = UUID().uuidString
        requestID = id
        request.requestID = id
        // The answer so far, as the core streams it.
        let progress = services.core.observe { [weak self] event in
            // Only while it's still the current request: a cancelled one may send one more piece.
            guard case .askDelta(id, let text) = event, self?.requestID == id else { return }
            self?.panel.streamed(text)
        }
        defer {
            progress.cancel()
            if requestID == id { requestID = nil }
        }
        do {
            return try await services.core.perform(.askRun, encoding: request, as: Answer.self).text
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
                services.toast.show(L("Copied the rewrite"), detail: error.localizedDescription, style: .info)
            }
        }
    }
}
