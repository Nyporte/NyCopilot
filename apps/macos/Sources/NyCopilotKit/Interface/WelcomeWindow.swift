import AppKit
import MacPlatform

/// The setup guide, by goal: pick what you want help with (each is a module; the rest stay out of
/// the way), how one-press shortcuts should work on your keyboard, then the permission and the
/// optional model. Opens on first launch and from Settings → General.
@MainActor
final class WelcomeWindow: NSWindowController, NSWindowDelegate {
    private struct Goal {
        let module: String
        let title: String
        let detail: String
        /// The shortcut shown beside it.
        let action: String?
        var fixedKeys: String? = nil
        /// A module that also has its own switch (off until asked for) is checked only with both on.
        var enabled: SettingKey? = nil
    }

    private static let goals: [Goal] = [
        Goal(module: "translate", title: L("Translate what I write and read"),
             detail: L("Write in any language; read selections and the whole screen in yours."), action: TranslateShell.Action.compose),
        Goal(module: "capture", title: L("Capture and mark up the screen"),
             detail: L("Screenshots with arrows and text; pin them; capture long pages."), action: CaptureShell.Action.capture),
        Goal(module: "ask", title: L("Ask AI about anything"),
             detail: L("Explain, summarize, or rewrite what you select or capture."), action: AskShell.Action.open),
        Goal(module: "inbox", title: L("Catch thoughts for later"),
             detail: L("One key to jot a thought or keep a selection; deal with it later."), action: InboxShell.Action.capture),
        Goal(module: "clipboard", title: L("Remember what I copy"),
             detail: L("Everything you copy, text and images, ready to paste again."), action: ClipboardShell.Action.open),
        Goal(module: "windows", title: L("Arrange windows"),
             detail: L("Halves, thirds, and corners, by shortcut or by dragging."), action: nil, fixedKeys: "⌃⌥ ← →"),
        Goal(module: "menubar", title: L("Tidy the menu bar"),
             detail: L("Hide the menu bar icons you rarely need; one click shows them."), action: MenuBarShell.Action.toggle,
             enabled: .menuBarEnabled),
        Goal(module: "clock", title: L("Show the time in another time zone"),
             detail: L("A clock in the menu bar for any city; others a click away."), action: nil, enabled: .clockEnabled)
    ]

    private let services: CopilotServices
    private var goalRows: [(goal: Goal, box: NSButton, keys: NSTextField)] = []
    private let scheme = NSSegmentedControl(labels: KeyScheme.allCases.map(\.title), trackingMode: .selectOne, target: nil, action: nil)
    private let accessStep = StepRow(number: 1, title: L("Allow Accessibility"),
                                     detail: L("To read what you select, paste results back, and move windows."))
    private let modelStep = StepRow(number: 2, title: L("Connect a model (optional)"), detail: "")
    private var poll: Timer?
    var onFinish: (() -> Void)?

    init(services: CopilotServices) {
        self.services = services
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 640),
                              styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: true)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self

        let icon = NSImageView(image: NSApp.applicationIconImage)
        icon.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([icon.widthAnchor.constraint(equalToConstant: 48), icon.heightAnchor.constraint(equalToConstant: 48)])
        let title = Design.label(L("Welcome to NyCopilot"), size: 22, weight: .bold)
        let subtitle = Design.wrapping(L("Pick what you want help with. You can change any of it later in Settings."), size: 13)
        subtitle.alignment = .center
        let header = Design.vstack([icon, title, subtitle], spacing: 6, alignment: .centerX)
        header.setCustomSpacing(8, after: icon)

        let goals = FormSection(L("What should NyCopilot do?"), rows: Self.goals.map(makeRow))

        scheme.target = self
        scheme.action = #selector(schemeChanged)
        let keyboard = FormSection(L("Shortcuts"), footer: KeyScheme.functionKeysAreStandard
            ? L("Your F-keys send F1, F2…, so F1 to F4 are one press. ⌥⌘/ shows every shortcut any time.")
            : L("Your F-keys control brightness and volume unless you hold fn, so ⌥⌘ letters are easier. ⌥⌘/ shows every shortcut any time."),
            rows: [FormRow(L("One-press keys"), subtitle: L("Screenshot, Translate, Inbox, and Ask AI"), accessory: scheme)])

        accessStep.button.title = L("Allow…")
        accessStep.button.target = self
        accessStep.button.action = #selector(allowAccess)
        modelStep.button.title = L("Set Up…")
        modelStep.button.target = self
        modelStep.button.action = #selector(setUpModel)
        let setup = FormSection(L("Setup"), rows: [accessStep, modelStep])

        let done = Design.button(L("Get Started"), target: self, action: #selector(finish), primary: true)
        done.controlSize = .large
        let root = Design.vstack([header, goals, keyboard, setup, done], spacing: 12, alignment: .centerX)
        root.translatesAutoresizingMaskIntoConstraints = false
        let content = NSVisualEffectView()
        content.material = .windowBackground
        content.blendingMode = .behindWindow
        content.state = .followsWindowActiveState
        content.addSubview(root)
        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 32),
            root.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -32),
            root.topAnchor.constraint(equalTo: content.topAnchor, constant: 30),
            root.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -18),
            goals.widthAnchor.constraint(equalTo: root.widthAnchor),
            keyboard.widthAnchor.constraint(equalTo: root.widthAnchor),
            setup.widthAnchor.constraint(equalTo: root.widthAnchor),
            subtitle.widthAnchor.constraint(lessThanOrEqualTo: root.widthAnchor),
            content.widthAnchor.constraint(equalToConstant: 600)
        ])
        window.contentView = content
    }

    required init?(coder: NSCoder) { fatalError("Use init(services:)") }

    /// A goal: a checkbox, what it does, and the key that starts it.
    private func makeRow(_ goal: Goal) -> NSView {
        let box = NSButton(checkboxWithTitle: "", target: self, action: #selector(goalToggled))
        let title = Design.label(goal.title, size: 13, weight: .semibold)
        let detail = Design.label(goal.detail, size: 11.5, color: .secondaryLabelColor)
        detail.lineBreakMode = .byTruncatingTail
        detail.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let text = Design.vstack([title, detail], spacing: 2)
        text.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let keys = Design.label("", size: 12, weight: .medium, color: .secondaryLabelColor)
        keys.font = .monospacedSystemFont(ofSize: 12, weight: .medium)
        keys.alignment = .right
        keys.widthAnchor.constraint(equalToConstant: 76).isActive = true
        let row = Design.hstack([box, text, Design.spacer(), keys], spacing: 10)
        row.alignment = .centerY
        // Tight enough that every goal fits on a 13-inch laptop screen.
        row.edgeInsets = NSEdgeInsets(top: 7, left: 12, bottom: 7, right: 14)
        goalRows.append((goal, box, keys))
        return row
    }

    func present() {
        prepare()
        window?.center()
        NSApp.bringForward()
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        // Permission is granted in System Settings and the model in Settings, so re-check while open.
        poll?.invalidate()
        poll = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    /// Everything `present` does but show the window.
    func prepare() {
        // Only modules this build loaded.
        let loaded = Set(services.moduleList().map(\.id))
        for row in goalRows {
            row.box.superview?.isHidden = !loaded.contains(row.goal.module)
            let enabled = row.goal.enabled.map { services.core.setting($0, default: false) } ?? true
            row.box.state = services.isModuleOn(row.goal.module) && enabled ? .on : .off
        }
        let current = services.preferences.hasCompletedWelcome ? KeyScheme.current(services.preferences) : KeyScheme.recommended
        scheme.selectedSegment = KeyScheme.allCases.firstIndex(of: current) ?? 0
        refresh()
        window?.setContentSize(window?.contentView?.fittingSize ?? .zero)
    }

    private var chosenScheme: KeyScheme { KeyScheme.allCases[max(0, scheme.selectedSegment)] }

    private func refresh() {
        accessStep.isComplete = Accessibility.isTrusted
        modelStep.isComplete = services.preferences.provider.isComplete
        modelStep.detail = SystemTranslation.isAvailable
            ? L("Translation already works through macOS. A model adds Ask AI and screen translation.")
            : L("Any OpenAI-compatible endpoint, hosted or local. Translation and Ask AI need it, or Google or Volcengine for translation.")
        let schemeKeys = chosenScheme.combinations
        for row in goalRows {
            // `combination(for:)` is already the default unless the shortcut was turned off.
            let combination = row.goal.action.flatMap { schemeKeys[$0] ?? services.hotKeys.combination(for: $0) }
            row.keys.stringValue = row.goal.fixedKeys ?? combination.map(KeyNames.display) ?? ""
            row.keys.alphaValue = row.box.state == .on ? 1 : 0.35
        }
    }

    @objc private func goalToggled() { refresh() }
    @objc private func schemeChanged() { refresh() }
    @objc private func allowAccess() { Accessibility.requestAccess() }
    @objc private func setUpModel() { services.openSettings("model") }

    /// Modules on or off as checked, the shortcuts in the chosen scheme.
    @objc private func finish() {
        for row in goalRows where row.box.superview?.isHidden == false {
            services.setModule(row.goal.module, row.box.state == .on)
            if let enabled = row.goal.enabled { try? services.core.setSetting(enabled, row.box.state == .on) }
        }
        let failures = chosenScheme.apply(services)
        services.preferences.hasCompletedWelcome = true
        window?.close()
        let help = services.hotKeys.combination(for: AppDelegate.showShortcutsAction).map(KeyNames.display) ?? "⌥⌘/"
        if failures.isEmpty {
            services.toast.show(L("You’re set"), detail: L("%@ shows every shortcut; ? shows the keys of whatever you’re in.", help), style: .success)
        } else {
            services.toast.show(L("Some shortcuts are taken by another app"), detail: L("Choose others in Settings. %@ shows them all.", help), style: .warning)
        }
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
            row.topAnchor.constraint(equalTo: topAnchor, constant: 7),
            row.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -7)
        ])
    }

    required init?(coder: NSCoder) { fatalError("Use init(number:title:detail:)") }
}
