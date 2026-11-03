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
| `clipboard.read` | Read images, text, and colors from the clipboard. |
| `pointer.watch` | Observe global mouse drags (drag snapping). |
| `pointer.control` | Set a pointing device's resolution and acceleration. |
| `statusbar.control` | Put items in the system menu bar and set their width (hiding the items beside them). |
| `network` | Outbound HTTP (every platform, including the server). |

## Current

| Module | Core (Rust) | macOS shell | Status |
| --- | --- | --- | --- |
| `llm` — Model | Provider settings, Chat Completions client, connection test | Model pane in Settings, Keychain | Shipped |
| `translate` — Translate | ordered translation engines (Google Translate via an Apps Script web app, Volcengine, the model) with fallback, editable instructions, favorite languages and Tab cycling, badge codes and native names, whitespace trimming, history collection, legacy import | Composer at the text cursor, selection translation on a card (tap the shortcut with text selected outside a text field), screen translation (hold the shortcut: Vision OCR highlights every line Live Text–style, a translation card on hover in a language picked from the capsule, live change tracking, click-through overlay), capture and paste, History window, Translate pane (language list, engines, Google and Volcengine setup, instructions, shortcuts) | Shipped |
| `windows` — Window Layouts | Layout geometry (halves, corners, thirds, maximize, center, resize), gaps, size cycling, display moves, drag snap areas | Shortcuts, Accessibility window moves, restore memory, drag monitor and preview, Windows pane | Shipped |
| `clipboard` — Clipboard history | `clipboard.items`: one entry per distinct text or image (by digest; moved to the top when copied again), `clipboard.pinned` (never pruned), excluded apps (password managers by default), retention by days and count through `Core::prune_records` | Pasteboard watcher (skips concealed, transient, and generated content, copied files, and NyCopilot's own temporary writes; images kept as PNGs in `Clipboard/`), picker near the pointer (pinned first, thumbnails, search, ↩ / ⌘1–9 paste back into the captured field, ⌘C, ⌘P pin, ⌘R / ⌘I / ⌘A verbs, ⌘⌫), Clipboard pane | Shipped |
| `inbox` — Inbox | `inbox.notes` and `inbox.done` (kept 30 days): text and/or a screenshot file name (validated as `<uuid>.png`), the app, window title, and address it came from, and its source; editing through `Core::update_record`; done/undone moves between the two; a waiting count through `Core::count_records` | F3 capture bar (upper part of the screen, source tag, ↩ saves and closes, Esc keeps a draft); F3 with a selection files it (Accessibility, or ⌘C with the clipboard put back) with its source read through Accessibility; screenshots filed from the capture toolbar (I) as PNGs in `Inbox/`; ⇧F3 inbox window (by-day list, detail with in-place editing, Space done, S send to Reminders (EventKit), Notes (Apple Events), or a Markdown folder, L snooze, R / A / P verbs, ⌘O open source, ⌫ delete, ⌘Z undo, search, Inbox/Later/Done tabs); snoozed notes woken on a timer with a toast; count in the menu; Inbox pane | Shipped |
| `ask` — Ask AI | `ask.run`: explain, summarize, rewrite, or a question about text and/or a screenshot, with follow-up turns; prompts and bounds; `ask.send_images` | F4 (⌥⌘A with ⌥⌘ letters) on the selection (a selection in an editable field can be replaced by the answer), A on screenshots, pins, inbox notes, ⌘A in the clipboard list; the Ask panel (actions, transcript, follow-ups, ⌘C / ⌘I / ⌘P / ⌘↩); screenshots downscaled and their text read on device | Shipped |
| `capture` — Screenshot & Pin | Output settings (folder, format, file name pattern), annotation style, pin shadow, capture history and recent regions, safe file names | Screen freeze per display, window detection, selection and magnifier, eight annotation tools, copy/save/pin, in-place text selection with macOS Live Text (captures and pins), translating a capture's text (R) on Translate's card, scrolling capture (streams the scroll area around the selection, stitches the selection in document coordinates in both directions, fixed header/footer detection), pins (zoom, opacity, rotate, flip, click-through; kept across launches as PNGs plus `Pins/pins.json`), pin clipboard, Screenshot pane | Shipped |
| `mouse` — Mouse | Speed (0.1–8× a fixed 400 counts per inch, whatever a mouse claims; without acceleration, points per count) and acceleration (0 = off, or following the system's) as a device's resolution, acceleration, and linear scaling; reversing the wheel, smooth scrolling (lines a click, glide time, apps left alone) | Connected mice through the HID event system (trackpads keep the system's settings), applied when a setting changes, a mouse connects, the Mac wakes, or System Settings changes, and put back when it's turned off or NyCopilot quits; an event tap on non-continuous (wheel) scrolling that reverses it and, for smooth scrolling, swallows each click and posts its distance as continuous scrolls on each display frame along a cubic curve that keeps the current speed and ends at rest (stretched to bridge the gap to the next click while spinning, whole points only) (⇧ sideways, ⌥ five times as far, ⌘/⌃ untouched; the frontmost app's exceptions); Mouse pane (sliders and typed values, app list) | Shipped |
| `menubar` — Menu Bar | Settings: on or off, whether the icons beyond the divider are hidden now (kept across launches), and how long shown icons stay (0–600 s, 0 = until hidden again) | A divider and a chevron as status items (placed by macOS and remembered by name; the first time, left of NyCopilot's icon); hiding sets the divider's length to 10,000 pt so every status item left of it is pushed past the screen's left edge, showing sets it back to 2 pt (an 18 pt gap with macOS's padding) whose line is drawn only while ⌘ is held (a global and a local `flagsChanged` monitor; always without Accessibility); never hides while the divider's right edge is right of the chevron; a one-shot timer hides shown icons again unless the pointer is on a menu bar; the chevron's right-click menu, a menu bar menu item, an optional shortcut, a setup-guide goal, and the Menu Bar pane. Planned next: a bar under the menu bar that shows the hidden icons (see [menubar-hidden-bar.md](menubar-hidden-bar.md)) | Shipped |

Every module's things share four verbs with the same keys (`Verb` in the macOS client): R translate, I keep
in the inbox, A ask AI, P pin — with ⌘ where you type. A module offers them through `CopilotServices.act`.

## Planned

| Module | Core owns | Client owns | Capabilities |
| --- | --- | --- | --- |
| `kanban` — Boards | Boards, columns, and cards as records; ordering; sync-friendly edits | Board UI | — (runs anywhere, including the server) |

Pinned images are kept by the macOS client today; keeping them as core records would let them sync.

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
