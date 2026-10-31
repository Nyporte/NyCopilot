// swift-tools-version: 5.9
import Foundation
import PackageDescription

// The macOS client: a native AppKit shell over the shared Rust core in ../../crates.
// Build the core first (`make core` at the repository root); the shell links its static library.
let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../..").standardizedFileURL.path
let coreProfile = ProcessInfo.processInfo.environment["NY_CORE_PROFILE"] ?? "release"

let package = Package(
    name: "NyCopilot",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "NyCopilot", targets: ["NyCopilot"])],
    targets: [
        .systemLibrary(name: "CNyCore", path: "Sources/CNyCore"),
        // macOS-only mechanics (focus handoff, clipboard, shortcuts) that the core cannot own.
        .target(name: "MacPlatform"),
        // The whole app, as a library so tests can reach it; the executable only starts it.
        .target(
            name: "NyCopilotKit",
            dependencies: ["CNyCore", "MacPlatform"],
            // Every data race the compiler can see is reported (warnings for now; Swift 6 makes them errors).
            swiftSettings: [.enableExperimentalFeature("StrictConcurrency")],
            linkerSettings: [.unsafeFlags(["-L\(root)/target/\(coreProfile)"])]
        ),
        .executableTarget(
            name: "NyCopilot",
            dependencies: ["NyCopilotKit"],
            linkerSettings: [.unsafeFlags(["-L\(root)/target/\(coreProfile)"])]
        ),
        .testTarget(name: "MacPlatformTests", dependencies: ["MacPlatform"]),
        .testTarget(
            name: "NyCopilotKitTests",
            dependencies: ["NyCopilotKit"],
            linkerSettings: [.unsafeFlags(["-L\(root)/target/\(coreProfile)"])]
        )
    ]
)
