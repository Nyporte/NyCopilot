import AppKit

/// First-run guide: three steps with live status, so setup is obvious and finishes in a minute.
@MainActor
final class WelcomeWindow: NSWindowController, NSWindowDelegate {
    private let services: CopilotServices
    private let accessStep = StepRow(number: 1, title: "Allow Accessibility",
                                     detail: "Lets NyCopilot read the field you’re typing in and paste results back.")
    private let modelStep = StepRow(number: 2, title: "Connect a model",
                                    detail: "Any OpenAI-compatible endpoint — a hosted provider or a local server.")
    private let tryStep = StepRow(number: 3, title: "Try it",
                                  detail: "")
    private var poll: Timer?
    var onFinish: (() -> Void)?

    init(services: CopilotServices) {
        self.services = services
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 480),
                              styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: true)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self

        let icon = NSImageView(image: NSApp.applicationIconImage)
        icon.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([icon.widthAnchor.constraint(equalToConstant: 84), icon.heightAnchor.constraint(equalToConstant: 84)])
        let title = Design.label("Welcome to NyCopilot", size: 24, weight: .bold)
        let subtitle = Design.wrapping("Your AI copilot for every app on your Mac, one shortcut away.", size: 13.5)
        subtitle.alignment = .center
        let header = Design.vstack([icon, title, subtitle], spacing: 8, alignment: .centerX)
        header.setCustomSpacing(14, after: icon)

        accessStep.button.title = "Allow…"
        accessStep.button.target = self
        accessStep.button.action = #selector(allowAccess)
        modelStep.button.title = "Set Up…"
        modelStep.button.target = self
        modelStep.button.action = #selector(setUpModel)
        tryStep.button.isHidden = true
        let steps = FormSection(rows: [accessStep, modelStep, tryStep])

        let done = Design.button("Get Started", target: self, action: #selector(finish), primary: true)
        done.controlSize = .large
        let root = Design.vstack([header, steps, done], spacing: 28, alignment: .centerX)
        root.translatesAutoresizingMaskIntoConstraints = false
        let content = NSVisualEffectView()
        content.material = .windowBackground
        content.blendingMode = .behindWindow
        content.state = .followsWindowActiveState
        content.addSubview(root)
        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 36),
            root.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -36),
            root.topAnchor.constraint(equalTo: content.topAnchor, constant: 44),
            root.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -28),
            steps.widthAnchor.constraint(equalTo: root.widthAnchor),
            subtitle.widthAnchor.constraint(lessThanOrEqualTo: root.widthAnchor),
            content.widthAnchor.constraint(equalToConstant: 520)
        ])
        window.contentView = content
    }

    required init?(coder: NSCoder) { fatalError("Use init(services:)") }

    func present() {
        refresh()
        window?.setContentSize(window?.contentView?.fittingSize ?? .zero)
        window?.center()
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        // Steps complete in other windows and apps, so re-check while the guide is open.
        poll?.invalidate()
        poll = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    private func refresh() {
        accessStep.isComplete = Accessibility.isTrusted
        modelStep.isComplete = services.preferences.provider.isComplete
        let shortcut = services.hotKeys.combination(for: TranslateShell.Action.compose).map(KeyNames.display) ?? "your shortcut"
        tryStep.detail = "Click in any text field, press \(shortcut), type, and hit Return. The translation replaces your text."
        tryStep.isComplete = false
    }

    @objc private func allowAccess() { Accessibility.requestAccess() }
    @objc private func setUpModel() { services.openSettings("model") }

    @objc private func finish() {
        services.preferences.hasCompletedWelcome = true
        window?.close()
    }

    func windowWillClose(_ notification: Notification) {
        poll?.invalidate()
        onFinish?()
    }
}

/// One numbered setup step: a badge that turns into a check mark, text, and an action button.
private final class StepRow: NSView {
    let button = Design.button("", target: nil, action: nil)
    private let badge = AppearanceView()
    private let number: NSTextField
    private let check = Design.symbol("checkmark", size: 11, weight: .bold, color: .white)
    private let detailLabel: NSTextField

    var isComplete = false {
        didSet {
            badge.fill = isComplete ? .systemGreen : .quaternaryLabelColor
            number.isHidden = isComplete
            check.isHidden = !isComplete
            button.isHidden = isComplete || button.title.isEmpty
        }
    }

    var detail: String {
        get { detailLabel.stringValue }
        set { detailLabel.stringValue = newValue }
    }

    init(number: Int, title: String, detail: String) {
        self.number = Design.label("\(number)", size: 12, weight: .semibold, color: .secondaryLabelColor)
        detailLabel = Design.wrapping(detail, size: 12)
        super.init(frame: .zero)
        badge.radius = 11
        badge.fill = .quaternaryLabelColor
        badge.translatesAutoresizingMaskIntoConstraints = false
        for view in [self.number, check] {
            view.translatesAutoresizingMaskIntoConstraints = false
            badge.addSubview(view)
            view.centerXAnchor.constraint(equalTo: badge.centerXAnchor).isActive = true
            view.centerYAnchor.constraint(equalTo: badge.centerYAnchor).isActive = true
        }
        check.isHidden = true
        let text = Design.vstack([Design.label(title, size: 13, weight: .semibold), detailLabel], spacing: 3)
        text.setContentHuggingPriority(.defaultLow, for: .horizontal)
        detailLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let row = Design.hstack([badge, text, button], spacing: 12)
        row.alignment = .centerY
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            badge.widthAnchor.constraint(equalToConstant: 22),
            badge.heightAnchor.constraint(equalToConstant: 22),
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            row.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            row.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12)
        ])
    }

    required init?(coder: NSCoder) { fatalError("Use init(number:title:detail:)") }
}
