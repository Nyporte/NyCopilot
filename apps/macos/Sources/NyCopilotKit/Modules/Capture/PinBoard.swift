import AppKit
@preconcurrency import VisionKit

/// Every open pin: create, hide and show together, close together, restore clicks.
@MainActor
final class PinBoard {
    var onSave: ((NSImage) -> Void)?
    var onVerb: ((Verb, PinWindow) -> Void)?
    var pins: [PinWindow] = []
    var areHidden = false
    /// Clicks in other apps, which unfocus every pin; installed only while pins exist.
    var outsideClicks: Any?

    /// Where open pins are kept between launches: each image as a PNG, and `pins.json` with how
    /// each looks and where it is.
    let folder = Preferences.dataDirectory.appendingPathComponent("Pins", isDirectory: true)
    var index: URL { folder.appendingPathComponent("pins.json") }

    @discardableResult
    func pin(_ image: NSImage, at frame: NSRect, shadow: Bool) -> PinWindow {
        let pin = add(PinWindow(image: image, frame: frame, shadow: shadow))
        keep(image, as: pin.id)
        persist()
        return pin
    }

    func add(_ pin: PinWindow) -> PinWindow {
        pin.onSave = { [weak self] image in self?.onSave?(image) }
        pin.onVerb = { [weak self] verb, pin in self?.onVerb?(verb, pin) }
        pin.onClose = { [weak self] closed in
            self?.pins.removeAll { $0 === closed }
            self?.updateMonitor()
            if let folder = self?.folder { try? FileManager.default.removeItem(at: folder.appendingPathComponent("\(closed.id).png")) }
            self?.persist()
        }
        pin.onCloseAll = { [weak self] in self?.closeAll() }
        pin.onFocus = { [weak self] focused in
            for other in self?.pins ?? [] where other !== focused { other.isFocused = false }
        }
        pins.append(pin)
        updateMonitor()
        if areHidden { showAll() }
        pin.orderFrontRegardless()
        return pin
    }

    /// Writes where every pin is and how it looks; called as pins come and go, and on quit.
    func persist() {
        let entries = pins.map { Entry(id: $0.id, state: $0.state) }
        guard let data = try? JSONEncoder().encode(entries) else { return }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try? data.write(to: index, options: .atomic)
    }

    /// The pins open at the last quit, back where they were; images no pin uses are cleared away.
    func restore() {
        let entries = (try? Data(contentsOf: index)).flatMap { try? JSONDecoder().decode([Entry].self, from: $0) } ?? []
        for entry in entries {
            let file = folder.appendingPathComponent("\(entry.id).png")
            guard let image = NSImage(contentsOf: file) else { continue }
            image.size = NSSize(width: entry.state.width, height: entry.state.height)
            let pin = add(PinWindow(image: image, frame: NSRect(origin: .zero, size: image.size), shadow: entry.state.shadow, id: entry.id))
            pin.apply(entry.state)
            // A display that's gone takes no pins with it.
            if !NSScreen.screens.contains(where: { $0.visibleFrame.intersects(pin.frame) }), let screen = NSScreen.main {
                pin.setFrameTopLeftPoint(NSPoint(x: screen.visibleFrame.midX - pin.frame.width / 2, y: screen.visibleFrame.maxY - 40))
            }
        }
        let kept = Set(pins.map { "\($0.id).png" })
        for file in (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [] where file.hasSuffix(".png") && !kept.contains(file) {
            try? FileManager.default.removeItem(at: folder.appendingPathComponent(file))
        }
        persist()
    }

    struct Entry: Codable {
        let id: UUID
        let state: PinWindow.State
    }

    /// The pin's original image, written off the main thread.
    func keep(_ image: NSImage, as id: UUID) {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
        let file = folder.appendingPathComponent("\(id).png"), folder = folder
        DispatchQueue.global(qos: .utility).async {
            guard let data = NSBitmapImageRep(cgImage: cgImage).representation(using: .png, properties: [:]) else { return }
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try? data.write(to: file, options: .atomic)
        }
    }

    func toggleVisibility() { areHidden ? showAll() : hideAll() }

    /// Whether a visible pin overlaps `rect` (AppKit screen coordinates).
    func covers(_ rect: NSRect) -> Bool { !areHidden && pins.contains { $0.isVisible && $0.frame.intersects(rect) } }

    func hideAll() {
        pins.forEach { $0.orderOut(nil) }
        areHidden = true
    }

    func showAll() {
        pins.forEach { $0.orderFrontRegardless() }
        areHidden = false
    }

    func closeAll() { pins.forEach { $0.close() } }

    var hasClickThrough: Bool { pins.contains { $0.isClickThrough } }

    func updateMonitor() {
        if pins.isEmpty, let monitor = outsideClicks {
            NSEvent.removeMonitor(monitor)
            outsideClicks = nil
        } else if !pins.isEmpty, outsideClicks == nil {
            outsideClicks = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
                MainActor.assumeIsolated { self?.unfocusAll() }
            }
        }
    }

    func unfocusAll() { pins.forEach { $0.isFocused = false } }

    func makeAllClickable() { pins.forEach { $0.setClickThrough(false) } }
}
