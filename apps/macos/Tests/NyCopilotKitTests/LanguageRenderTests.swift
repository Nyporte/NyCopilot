import AppKit
import XCTest
@testable import NyCopilotKit

/// Every surface laid out in each of the interface's languages: no layout conflicts, nothing cut
/// off, and still a size that fits the screen. German and Russian run longest; Chinese, Japanese,
/// and Korean shortest but tallest.
@MainActor
final class LanguageRenderTests: XCTestCase {
    private var folder: URL!
    private var core: NyCore!
    private var saved: (Bundle, Locale)!

    override func setUp() async throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("languages-\(UUID())", isDirectory: true)
        core = try NyCore(dataDirectory: folder)
        saved = (Localization.bundle, Localization.locale)
    }

    override func tearDown() async throws {
        (Localization.bundle, Localization.locale) = saved
        core = nil
        try? FileManager.default.removeItem(at: folder)
    }

    private func use(_ language: String) throws {
        Localization.bundle = try LocalizationTests.bundle(language)
        Localization.locale = Locale(identifier: language)
    }

    private func check(_ view: NSView, _ name: String, file: StaticString = #filePath, line: UInt = #line) {
        Render.check(view, name, file: file, line: line)
        let cut = Render.clipped(view)
        XCTAssertTrue(cut.isEmpty, "\(name): cut off: \(cut.prefix(4))", file: file, line: line)
    }

    private func services() -> CopilotServices {
        let preferences = Preferences(core: core)
        let services = CopilotServices(core: core, preferences: preferences, hotKeys: HotKeyCenter(preferences: preferences))
        services.moduleList = { [("translate", L("Translate"), ""), ("capture", L("Screenshot & Pin"), ""), ("ask", L("Ask AI"), ""),
                                 ("inbox", L("Inbox"), ""), ("clipboard", L("Clipboard"), ""), ("windows", L("Window Layouts"), ""),
                                 ("menubar", L("Menu Bar"), ""),
                                 ("clock", L("Clock"), "")] }
        return services
    }

    func testSettingsInEveryLanguage() throws {
        for language in InterfaceLanguage.available.map(\.code) {
            try use(language)
            let services = services()
            let actions = ((try? core.call(.windowsActions, as: [WindowsShell.ActionInfo].self)) ?? [])
                .map { WindowsShell.ActionInfo(id: $0.id, title: L($0.title), group: L($0.group)) }
            let panes: [SettingsPane] = [GeneralPane(services: services), ModelPane(services: services), CapturePane(services: services),
                                         TranslatePane(services: services, openHistory: {}), InboxPane(services: services),
                                         ClipboardPane(services: services), WindowsPane(services: services, actions: actions),
                                         MousePane(services: services, connected: { ["ROG Keris II Origin"] }),
                                         MenuBarPane(services: services),
                                         ClockPane(services: services)]
            for pane in panes {
                let view = pane.view
                pane.paneWillAppear()
                view.setFrameSize(view.fittingSize)
                check(view, "\(language)-settings-\(pane.paneID)")
            }
        }
    }

    func testPanelsInEveryLanguage() throws {
        for language in InterfaceLanguage.available.map(\.code) {
            try use(language)
            let toolbar = CaptureToolbar(palette: [.systemRed, .systemBlue])
            check(toolbar, "\(language)-toolbar")

            for (name, groups) in [("capture", KeyGuide.capture), ("pin", KeyGuide.pin), ("inbox", KeyGuide.inbox),
                                   ("clipboard", KeyGuide.clipboard), ("ask", KeyGuide.ask)] {
                let panel = KeySheet.makePanel(name, groups: groups)
                check(panel.contentView!, "\(language)-keys-\(name)")
                XCTAssertLessThan(panel.frame.width, 1000, "\(language) \(name)")
            }

            let bar = RecordingBar(beside: NSRect(x: 200, y: 200, width: 400, height: 240), on: NSScreen.screens[0], shortcut: "F1")
            check(bar.contentView!, "\(language)-recording-ready")
            bar.showRecording()
            check(bar.contentView!, "\(language)-recording")
            let scroll = ScrollCapturePanel(beside: NSRect(x: 200, y: 200, width: 400, height: 300), on: NSScreen.screens[0])
            check(scroll.contentView!, "\(language)-scroll-panel")

            let welcome = WelcomeWindow(services: services())
            welcome.prepare()
            check(welcome.window!.contentView!, "\(language)-welcome")
            XCTAssertLessThanOrEqual(welcome.window!.contentView!.frame.height, 780, language)

            let ask = AskPanel()
            ask.prepare(AskMaterial(text: "", source: SourceContext()))
            check(ask.panel.contentView!, "\(language)-ask")
        }
    }

    func testInboxAndClipboardInEveryLanguage() throws {
        let images = ImageFolder("languages-images-\(UUID())")
        defer { images.removeAll() }
        _ = try core.call(.inboxAdd, ["text": "Call Lin", "app": "Safari", "title": "Plan"])
        _ = try core.call(.clipboardAdd, ["text": "my address"])
        for language in InterfaceLanguage.available.map(\.code) {
            try use(language)
            let window = InboxWindow(core: core, images: images, toast: Toast())
            window.reload()
            check(try XCTUnwrap(window.window?.contentView), "\(language)-inbox")
            let picker = ClipboardPicker(core: core, images: images)
            picker.prepare(target: nil, source: nil)
            check(picker.panel.contentView!, "\(language)-clipboard")
        }
    }
}
