import AppKit
import ApplicationServices

/// An accessibility element's frame on screen, in global top-left coordinates.
enum AccessibilityFrame {
    static func of(_ element: AXUIElement) -> CGRect? {
        var position = CGPoint.zero, size = CGSize.zero
        guard let origin = value(element, kAXPositionAttribute), AXValueGetValue(origin, .cgPoint, &position),
              let extent = value(element, kAXSizeAttribute), AXValueGetValue(extent, .cgSize, &size),
              size.width > 0, size.height > 0 else { return nil }
        return CGRect(origin: position, size: size)
    }

    private static func value(_ element: AXUIElement, _ name: String) -> AXValue? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        return unsafeBitCast(value, to: AXValue.self)
    }
}

/// The visible parts of one window as a fixed tree: the window, the panes in it, the cards and bars
/// in those, the controls in them. Built once per capture, so pointing at the same spot always finds
/// the same part, and parts side by side sit at the same depth.
struct RegionTree: Sendable {
    struct Node: Sendable {
        /// Global top-left points.
        let rect: CGRect
        /// The window is 0, the parts directly in it 1, and so on.
        let depth: Int
        var children: [Int] = []
    }

    /// `nodes[0]` is the window.
    let nodes: [Node]

    /// From the smallest part under `point` out to the window: at each step down, the smallest child
    /// containing the point.
    func path(at point: CGPoint) -> [Node] {
        var path = [nodes[0]]
        var current = 0
        while let next = nodes[current].children.filter({ nodes[$0].rect.contains(point) })
            .min(by: { nodes[$0].rect.width * nodes[$0].rect.height < nodes[$1].rect.width * nodes[$1].rect.height }) {
            path.append(nodes[next])
            current = next
        }
        return path.reversed()
    }
}

/// Reads a window's accessibility tree, keeps what can be seen, and nests it (see `VisibleLevels`).
enum RegionBuilder {
    /// Kinds that are capture targets in their own right even without a drawn box around them.
    static let controlRoles: Set<String> = [
        kAXButtonRole, kAXTextFieldRole, kAXCheckBoxRole, kAXRadioButtonRole, kAXPopUpButtonRole, kAXSliderRole,
        kAXRowRole, kAXComboBoxRole, "AXLink", kAXMenuButtonRole, kAXImageRole
    ]

    /// Parts read per window and time spent, so one heavy web page doesn't hold up the capture.
    static let nodeLimit = 2500
    static let timeLimit: TimeInterval = 0.5

    static func tree(for window: FrozenScreen.Window, pixels: GreyPixels?) -> RegionTree {
        let started = Date()
        let root = RegionTree.Node(rect: window.rect, depth: 0)
        guard AXIsProcessTrusted(), window.pid > 0, let element = windowElement(for: window) else { return RegionTree(nodes: [root]) }
        var layers = read(from: element, in: window.rect)
        // An Electron app asked just now builds its tree a moment later.
        if layers.count < 3 {
            Thread.sleep(forTimeInterval: 0.25)
            layers = read(from: element, in: window.rect)
        }
        let tree = nest(reduce(layers, window: window.rect, pixels: pixels), in: window.rect)
        let app = NSRunningApplication(processIdentifier: window.pid)?.localizedName ?? "?"
        Diagnostics.note("capture", "mapped \(app) \(Int(window.rect.width))×\(Int(window.rect.height)): \(layers.count) parts read, "
                         + "\(tree.nodes.count - 1) visible, \(tree.nodes.map(\.depth).max() ?? 0) deep, \(Int(Date().timeIntervalSince(started) * 1000)) ms")
        return tree
    }

    /// The app's own element for this window: a window (or, for the Dock, its bar) with the same frame.
    private static func windowElement(for window: FrozenScreen.Window) -> AXUIElement? {
        let app = AXUIElementCreateApplication(window.pid)
        AXUIElementSetMessagingTimeout(app, 0.2)
        // Electron apps keep their content out of Accessibility until asked; the tree fills in shortly.
        _ = AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        var options: [AXUIElement] = []
        for name in [kAXWindowsAttribute, kAXChildrenAttribute] {
            var value: CFTypeRef?
            if AXUIElementCopyAttributeValue(app, name as CFString, &value) == .success, let list = value as? [AXUIElement] { options += list }
        }
        return options.first { element in
            guard let frame = AccessibilityFrame.of(element) else { return false }
            return abs(frame.minX - window.rect.minX) <= 6 && abs(frame.minY - window.rect.minY) <= 6
                && abs(frame.maxX - window.rect.maxX) <= 6 && abs(frame.maxY - window.rect.maxY) <= 6
        }
    }

    /// Every part inside the window, breadth first (so the large ones are all there if time runs
    /// out), skipping what's scrolled out of view or too small to hold anything.
    private static func read(from root: AXUIElement, in window: CGRect) -> [(rect: CGRect, role: String?)] {
        let deadline = Date().addingTimeInterval(timeLimit)
        let names = [kAXRoleAttribute, kAXPositionAttribute, kAXSizeAttribute, kAXChildrenAttribute] as CFArray
        var queue: [AXUIElement] = [root]
        var head = 0
        var found: [(rect: CGRect, role: String?)] = []
        while head < queue.count, head < nodeLimit, Date() < deadline {
            let element = queue[head]
            head += 1
            AXUIElementSetMessagingTimeout(element, 0.1)
            var values: CFArray?
            guard AXUIElementCopyMultipleAttributeValues(element, names, AXCopyMultipleAttributeOptions(rawValue: 0), &values) == .success,
                  let list = values as? [Any], list.count == 4 else { continue }
            let role = list[0] as? String
            var position = CGPoint.zero, size = CGSize.zero
            let hasFrame = axValue(list[1]).map { AXValueGetValue($0, .cgPoint, &position) } == true
                && axValue(list[2]).map { AXValueGetValue($0, .cgSize, &size) } == true
            if hasFrame {
                let frame = CGRect(origin: position, size: size).intersection(window)
                // Out of view, or too small to contain a part worth taking: nothing below it either.
                guard !frame.isNull, frame.width >= 8, frame.height >= 8 else { continue }
                // The window's own frame is the tree's root already.
                if head > 1 { found.append((frame.integral, role)) }
            }
            if role == kAXStaticTextRole || role == kAXImageRole { continue }
            if let children = list[3] as? [AXUIElement] { queue += children.prefix(400) }
        }
        return found
    }

    private static func axValue(_ value: Any) -> AXValue? {
        let object = value as CFTypeRef
        return CFGetTypeID(object) == AXValueGetTypeID() ? unsafeBitCast(object, to: AXValue.self) : nil
    }

    /// The parts you can see: each snapped onto the edges drawn around it, kept when it's visibly a
    /// box, a kind people capture, or a control; near-identical ones become one.
    static func reduce(_ layers: [(rect: CGRect, role: String?)], window: CGRect, pixels: GreyPixels?) -> [CGRect] {
        var kept: [(rect: CGRect, score: Int)] = []
        var seen: Set<[Int]> = []
        for layer in layers where layer.rect.width >= 12 && layer.rect.height >= 12 {
            // Many layers share a frame exactly; judge each frame once.
            guard seen.insert([Int(layer.rect.minX), Int(layer.rect.minY), Int(layer.rect.width), Int(layer.rect.height)]).inserted else { continue }
            let (rect, sides) = pixels.map { VisibleLevels.snapped(layer.rect, in: $0, window: window) } ?? (layer.rect, 4)
            let role = layer.role ?? ""
            let meaningful = VisibleLevels.meaningfulRoles.contains(role), control = controlRoles.contains(role)
            guard sides >= 3 || meaningful || control, !VisibleLevels.resembles(rect, window) else { continue }
            let score = sides * 2 + (meaningful || control ? 1 : 0)
            if let twin = kept.firstIndex(where: { VisibleLevels.resembles($0.rect, rect) }) {
                if score > kept[twin].score { kept[twin] = (rect, score) }
            } else {
                kept.append((rect, score))
            }
        }
        return kept.map(\.rect)
    }

    /// Each part goes inside the smallest larger part that contains it (or the window), largest first,
    /// so depths count visible containers only.
    static func nest(_ rects: [CGRect], in window: CGRect) -> RegionTree {
        var nodes = [RegionTree.Node(rect: window, depth: 0)]
        for rect in rects.sorted(by: { $0.width * $0.height > $1.width * $1.height }) {
            let parent = nodes.indices.filter { nodes[$0].rect.insetBy(dx: -3, dy: -3).contains(rect) }
                .min { nodes[$0].rect.width * nodes[$0].rect.height < nodes[$1].rect.width * nodes[$1].rect.height } ?? 0
            nodes.append(RegionTree.Node(rect: rect, depth: nodes[parent].depth + 1))
            nodes[parent].children.append(nodes.count - 1)
        }
        return RegionTree(nodes: nodes)
    }
}

/// The region trees of every window on one display during a capture: built in the background when
/// the capture opens, front window first (or the one under the pointer), one at a time.
@MainActor
final class RegionMap {
    /// Global top-left, front to back, as `FrozenScreen.windows` lists them (but global).
    private let windows: [FrozenScreen.Window]
    private var trees: [Int: RegionTree] = [:]
    private var order: [Int]
    private var building = false
    private var pixels: GreyPixels?
    /// A window's tree is ready; the hover can look it up now.
    var onReady: ((Int) -> Void)?

    init(windows: [FrozenScreen.Window]) {
        self.windows = windows
        order = Array(windows.indices)
    }

    func tree(for index: Int) -> RegionTree? { trees[index] }

    /// Starts building once the display's pixels are ready.
    func start(with pixels: GreyPixels?) {
        self.pixels = pixels
        buildNext()
    }

    /// The window under the pointer goes next.
    func prioritize(_ index: Int) {
        guard trees[index] == nil, let position = order.firstIndex(of: index) else { return }
        order.remove(at: position)
        order.insert(index, at: 0)
    }

    private func buildNext() {
        guard !building, let index = order.first else { return }
        order.removeFirst()
        building = true
        let window = windows[index], pixels = pixels
        Task { [weak self] in
            let tree = await Task.detached(priority: .userInitiated) { RegionBuilder.tree(for: window, pixels: pixels) }.value
            guard let self else { return }
            trees[index] = tree
            building = false
            onReady?(index)
            buildNext()
        }
    }
}
