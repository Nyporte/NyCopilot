import AppKit

/// Images a module keeps beside the database, each `<uuid>.png` (or `.gif`); records hold only the file name.
struct ImageFolder: Sendable {
    let url: URL

    init(_ name: String) { url = Preferences.dataDirectory.appendingPathComponent(name, isDirectory: true) }

    func file(_ name: String) -> URL { url.appendingPathComponent(name) }

    func image(_ name: String) -> NSImage? { NSImage(contentsOf: file(name)) }

    /// PNG data written under a new name; the name, or nil if it couldn't be written.
    func keep(png data: Data) -> String? {
        let name = "\(UUID().uuidString).png"
        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            try data.write(to: file(name), options: .atomic)
            return name
        } catch {
            return nil
        }
    }

    func keep(_ image: NSImage) -> String? {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let data = NSBitmapImageRep(cgImage: cgImage).representation(using: .png, properties: [:]) else { return nil }
        return keep(png: data)
    }

    /// Takes over a file no one else keeps, such as a finished recording: it moves in under a new
    /// name with its own extension. The name, or the reason it couldn't move.
    func keep(moving source: URL) throws -> String {
        let name = "\(UUID().uuidString).\(source.pathExtension.lowercased())"
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: source, to: file(name))
        // Kept from now on: `removeUnused`'s grace counts from here, not from when it was written.
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: file(name).path)
        return name
    }

    /// Removes files no record in `collections` names any more (entries pruned or deleted), off the
    /// main thread: it reads every record. Files younger than `graceSeconds` stay: one may be kept
    /// but not yet recorded.
    func removeUnused(core: NyCore, collections: [CoreCollection], graceSeconds: TimeInterval = 60) {
        Task.detached(priority: .utility) { [self] in sweep(core: core, collections: collections, graceSeconds: graceSeconds) }
    }

    private func sweep(core: NyCore, collections: [CoreCollection], graceSeconds: TimeInterval) {
        struct Entry: Decodable { let image: String? }
        var used: Set<String> = []
        for collection in collections {
            var before: String?
            repeat {
                // A failed read must not look like "nothing is used".
                guard let page = try? core.records(collection, as: Entry.self, limit: 500, before: before) else { return }
                used.formUnion(page.records.compactMap(\.data.image))
                before = page.next
            } while before != nil
        }
        let settled = Date().addingTimeInterval(-graceSeconds)
        for name in (try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? [] where !used.contains(name) {
            let modified = (try? file(name).resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            if modified < settled { try? FileManager.default.removeItem(at: file(name)) }
        }
    }

    func removeAll() { try? FileManager.default.removeItem(at: url) }
}
