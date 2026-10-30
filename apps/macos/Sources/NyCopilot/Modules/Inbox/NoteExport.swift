import AppKit
import EventKit

/// Sending an inbox note somewhere it gets done: Apple Reminders, Apple Notes, or a Markdown file in
/// a folder of yours (an Obsidian vault, a notes repository). Each keeps the note's source.
@MainActor
enum NoteExport {
    enum Destination: String, CaseIterable {
        case reminders, notes, markdown

        var title: String {
            switch self {
            case .reminders: "Reminders"
            case .notes: "Notes"
            case .markdown: "Markdown Folder"
            }
        }

        var symbol: String {
            switch self {
            case .reminders: "checklist"
            case .notes: "note.text"
            case .markdown: "doc.plaintext"
            }
        }
    }

    /// What a destination gets: the text split into a title and the rest, the source, the screenshot.
    struct Content {
        var text: String
        var image: URL?
        var source: String
        var address: URL?
        var created: Date

        var title: String {
            let first = text.split(whereSeparator: \.isNewline).first.map { String($0).trimmingCharacters(in: .whitespaces) } ?? ""
            return first.isEmpty ? (image == nil ? "Note" : "Screenshot") : String(first.prefix(200))
        }

        var body: String {
            let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
            return lines.dropFirst().joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    enum Failure: LocalizedError {
        case remindersDenied, noReminderList, notesFailed(String), noFolder

        var errorDescription: String? {
            switch self {
            case .remindersDenied: "NyCopilot isn’t allowed to add reminders. Allow it in System Settings → Privacy & Security → Reminders."
            case .noReminderList: "Reminders has no list to add to."
            case .notesFailed(let why): "Notes didn’t take the note: \(why)"
            case .noFolder: "Choose a folder for Markdown notes first."
            }
        }
    }

    /// The finished export: a short phrase for the confirmation, such as "Sent to Reminders".
    static func send(_ content: Content, to destination: Destination, core: NyCore) async throws -> String {
        switch destination {
        case .reminders: try await toReminders(content)
        case .notes: try await toNotes(content)
        case .markdown:
            guard let folder = markdownFolder(core: core, choosingIfNeeded: true) else { throw Failure.noFolder }
            let file = try toMarkdown(content, in: folder)
            return "Saved as \(file.lastPathComponent)"
        }
        return "Sent to \(destination.title)"
    }

    // MARK: Reminders

    private static func toReminders(_ content: Content) async throws {
        let store = EKEventStore()
        let granted: Bool
        if #available(macOS 14, *) { granted = try await store.requestFullAccessToReminders() }
        else { granted = try await store.requestAccess(to: .reminder) }
        guard granted else { throw Failure.remindersDenied }
        guard let list = store.defaultCalendarForNewReminders() else { throw Failure.noReminderList }
        let reminder = EKReminder(eventStore: store)
        reminder.calendar = list
        reminder.title = content.title
        reminder.notes = [content.body, content.source].filter { !$0.isEmpty }.joined(separator: "\n\n")
        reminder.url = content.address
        try store.save(reminder, commit: true)
    }

    // MARK: Notes

    /// Notes takes HTML through Apple Events; a screenshot goes in as an inline image.
    private static func toNotes(_ content: Content) async throws {
        var html = "<h1>\(escape(content.title))</h1>"
        if !content.body.isEmpty {
            html += content.body.split(separator: "\n", omittingEmptySubsequences: false).map { "<div>\(escape(String($0)).isEmpty ? "<br>" : escape(String($0)))</div>" }.joined()
        }
        if let image = content.image, let data = try? Data(contentsOf: image), data.count <= 8 * 1024 * 1024 {
            html += "<div><img src=\"data:image/png;base64,\(data.base64EncodedString())\"></div>"
        }
        if !content.source.isEmpty {
            let link = content.address.map { "<a href=\"\(escape($0.absoluteString))\">\(escape(content.source))</a>" } ?? escape(content.source)
            html += "<div><br></div><div><i>From \(link)</i></div>"
        }
        let script = "tell application \"Notes\" to make new note with properties {body:\"\(appleScriptString(html))\"}"
        // NSAppleScript belongs on the main thread; Notes answers within a moment.
        var error: NSDictionary?
        NSAppleScript(source: script)?.executeAndReturnError(&error)
        if let error { throw Failure.notesFailed((error[NSAppleScript.errorMessage] as? String) ?? "error \(error[NSAppleScript.errorNumber] ?? "")") }
    }

    private static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }

    private static func appleScriptString(_ text: String) -> String {
        text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }

    // MARK: Markdown

    /// The chosen folder; asks for one the first time (and when it has gone missing).
    static func markdownFolder(core: NyCore, choosingIfNeeded: Bool) -> URL? {
        let path: String = core.setting(.inboxMarkdownFolder, default: "")
        var isFolder: ObjCBool = false
        if !path.isEmpty, FileManager.default.fileExists(atPath: path, isDirectory: &isFolder), isFolder.boolValue {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        return choosingIfNeeded ? chooseMarkdownFolder(core: core) : nil
    }

    @discardableResult
    static func chooseMarkdownFolder(core: NyCore) -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Choose"
        panel.message = "Inbox notes you send as Markdown are saved here, one file each."
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        try? core.setSetting(.inboxMarkdownFolder, url.path)
        return url
    }

    /// `<date> <title>.md`, with front matter for the source; a screenshot is saved beside it.
    static func toMarkdown(_ content: Content, in folder: URL) throws -> URL {
        let stamp = DateFormatter()
        stamp.dateFormat = "yyyy-MM-dd HHmm"
        let unsafe = CharacterSet(charactersIn: "/\\:*?\"<>|#^[]").union(.newlines).union(.controlCharacters)
        let words = content.title.components(separatedBy: unsafe).joined(separator: " ").trimmingCharacters(in: .whitespaces).prefix(60)
        let stem = unique("\(stamp.string(from: content.created)) \(words)".trimmingCharacters(in: .whitespaces), in: folder)
        var lines = ["---", "created: \(ISO8601DateFormatter().string(from: content.created))"]
        if !content.source.isEmpty { lines.append("source: \"\(content.source.replacingOccurrences(of: "\"", with: "'"))\"") }
        if let address = content.address { lines.append("url: \(address.absoluteString)") }
        lines += ["tags: [inbox]", "---", "", content.text.trimmingCharacters(in: .whitespacesAndNewlines)]
        if let image = content.image {
            let name = "\(stem).png"
            try FileManager.default.copyItem(at: image, to: folder.appendingPathComponent(name))
            lines += ["", "![](\(name.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? name))"]
        }
        let file = folder.appendingPathComponent("\(stem).md")
        try (lines.joined(separator: "\n") + "\n").write(to: file, atomically: true, encoding: .utf8)
        return file
    }

    private static func unique(_ stem: String, in folder: URL) -> String {
        var candidate = stem, n = 2
        while FileManager.default.fileExists(atPath: folder.appendingPathComponent("\(candidate).md").path) {
            candidate = "\(stem) \(n)"
            n += 1
        }
        return candidate
    }
}

/// When a snoozed note comes back, as menu choices: later today, this evening, tomorrow, the
/// weekend, next week — the ones still ahead.
enum SnoozeChoice: CaseIterable {
    case laterToday, thisEvening, tomorrow, weekend, nextWeek

    var title: String {
        switch self {
        case .laterToday: "Later Today"
        case .thisEvening: "This Evening"
        case .tomorrow: "Tomorrow"
        case .weekend: "This Weekend"
        case .nextWeek: "Next Week"
        }
    }

    /// The time, or nil when it doesn't make sense now (this evening, at 8 pm).
    func date(from now: Date = Date(), calendar: Calendar = .current) -> Date? {
        func at(_ hour: Int, daysAhead: Int) -> Date? {
            calendar.date(byAdding: .day, value: daysAhead, to: calendar.date(bySettingHour: hour, minute: 0, second: 0, of: now) ?? now)
        }
        let hour = calendar.component(.hour, from: now)
        let weekday = calendar.component(.weekday, from: now) // 1 Sunday … 7 Saturday
        switch self {
        case .laterToday: return hour < 18 ? now.addingTimeInterval(3 * 3600) : nil
        case .thisEvening: return hour < 17 ? at(19, daysAhead: 0) : nil
        case .tomorrow: return at(9, daysAhead: 1)
        case .weekend: return (2...6).contains(weekday) ? at(9, daysAhead: 7 - weekday) : nil
        case .nextWeek: return at(9, daysAhead: (9 - weekday) % 7 == 0 ? 7 : (9 - weekday) % 7)
        }
    }
}
