import AppKit

/// Images a module keeps beside the database, each `<uuid>.png`; records hold only the file name.
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

    /// Removes files no record in `collections` names any more (entries pruned or deleted).
    @MainActor
    func removeUnused(core: NyCore, collections: [CoreCollection]) {
        struct Entry: Decodable { let image: String? }
        var used: Set<String> = []
        for collection in collections {
            var before: String?
            repeat {
                var params: [String: Any] = ["collection": collection.rawValue, "limit": 500]
                if let before { params["before"] = before }
                // A failed read must not look like "nothing is used".
                guard let page = try? core.call(.recordsList, params, as: CorePage<Entry>.self) else { return }
                used.formUnion(page.records.compactMap(\.data.image))
                before = page.next
            } while before != nil
        }
        for name in (try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? [] where !used.contains(name) {
            try? FileManager.default.removeItem(at: file(name))
        }
    }

    func removeAll() { try? FileManager.default.removeItem(at: url) }
}
