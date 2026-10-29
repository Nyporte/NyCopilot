# Modules

Each module splits into a platform-neutral **core module** (Rust) and a **client shell** per
platform. The manifest's `capabilities` list tells a client what it must provide; a client that
can't provide them doesn't load the module.

## Capability vocabulary

| Capability | Provided by the client |
| --- | --- |
| `hotkey` | Global keyboard shortcuts. |
| `text.capture` | Read the focused text field and selection (macOS Accessibility, Windows UI Automation). |
| `text.insert` | Paste into that field without clobbering the clipboard. |
| `clipboard.watch` | Observe clipboard changes. |
| `screen.capture` | Capture a region or window as an image. |
| `window.overlay` | Always-on-top panels (pinned images, quick chat). |
| `window.control` | Move and resize other apps' windows. |
| `network` | Outbound HTTP (every platform, including the server). |

## Current

| Module | Core (Rust) | macOS shell | Status |
| --- | --- | --- | --- |
| `llm` — Model | Provider settings, Chat Completions client, connection test | Model pane in Settings, Keychain | Shipped |
| `translate` — Translate | Prompt, language validation, history collection, legacy import | Composer overlay, capture & paste, History window, Translate pane | Shipped |

## Planned

| Module | Core owns | Client owns | Capabilities |
| --- | --- | --- | --- |
| `clipboard` — Clipboard history | `clipboard.items` collection, dedup, search, pins, retention policy, sensitive-content rules | Watching the pasteboard, picker panel, paste-back | `clipboard.watch`, `text.insert`, `hotkey` |
| `capture` — Screenshot & pin | `capture.shots` metadata, annotations as data, OCR/translate via `llm` | Region selection, capture, pinned floating images, annotation canvas | `screen.capture`, `window.overlay`, `hotkey` |
| `windows` — Window layouts | Named layouts and snap rules as settings | Moving/resizing windows, shortcut handling | `window.control`, `hotkey` |
| `chat` — Quick chat & agent | Conversations collection, agent loop, tool registry, streaming | Chat panel, rendering, tool permissions UI | `window.overlay`, `hotkey`, `network` |
| `kanban` — Boards | Boards, columns, and cards as records; ordering; sync-friendly edits | Board UI | — (runs anywhere, including the server) |

Translate will also grow "translate selection" and "translate screenshot" commands that reuse
`text.capture` and the `capture` module rather than adding new platform code.

## Adding a module

1. **Core:** create `crates/ny-modules/src/<id>.rs` implementing `ny_core::Module`. Declare every
   setting (with default and scope) and every collection (prefixed with the id) in the manifest.
   Keep it free of OS calls. Add it to `ny_modules::all()` and write unit tests against
   `Core::new(Store::open_in_memory()…)`.
2. **Protocol:** document its commands in [protocol.md](protocol.md).
3. **macOS shell:** add `apps/macos/Sources/NyCopilot/Modules/<Name>/` with a type conforming to
   `ModuleShell` (menu items, hotkey actions, optional `SettingsPane`), and list it in
   `AppDelegate.makeModules`. Use `CopilotServices` for the core, toasts, and Settings navigation.
4. Other clients repeat step 3 in their own language against the same protocol.

Rules of thumb: data and decisions go in the core; pixels and OS APIs go in the shell; secrets go
in the platform credential store and are passed per call; anything a server could do belongs in
the core.
