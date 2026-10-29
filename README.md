# NyCopilot

NyCopilot is a personal AI copilot that lives in your menu bar and works inside every app. It is
built as a foundation for many modules (translation, clipboard history, screenshots and pinning,
window management, quick chat with an agent, kanban) across several operating systems, with a
sync server to come.

The first module is **Translate**: click into any text field, press **⌥⌘T**, type in any language,
and press **Return**. The translation replaces what you selected, right where you were typing.

## How it's built

- **A shared Rust core** (`crates/`) owns data, settings, modules, and model access: one SQLite
  database of sync-ready records, typed settings with defaults, and a module registry.
- **Thin native clients** (`apps/`) own everything that needs the operating system. The macOS client
  is Swift/AppKit: menu bar, global shortcuts, Accessibility, paste, and Keychain.
- **One protocol.** Clients call the core with `ny_call(method, json)`. A future server will expose
  the same methods over the network.

See [spec/architecture.md](spec/architecture.md), [spec/protocol.md](spec/protocol.md), and
[spec/modules.md](spec/modules.md).

## Build and run

Requires macOS 13+, Xcode or Command Line Tools (Swift 5.9+), and Rust (stable, via rustup).

```sh
make build   # Rust core (release) + Swift app → dist/NyCopilot.app, ad-hoc signed
make run     # build and open
make test    # Rust tests (incl. loopback HTTP) + Swift tests; no permissions, no real API
```

Builds are signed with your Developer ID Application certificate (or Apple Development if that's
all you have) with the hardened runtime. macOS keys Accessibility and Keychain access to that
identity, so grants survive rebuilds and reinstalls. Without a certificate the build falls back to
an ad-hoc signature, prints a warning, and loses those grants on every rebuild. Pick a specific
certificate with `make build SIGN_IDENTITY='…'`. Notarize before sharing the app with others.

## First run

A short setup guide opens on first launch:

1. **Allow Accessibility.** NyCopilot uses it to find the focused field and paste into it. No
   other permission is needed.
2. **Connect a model.** Settings → Model takes any OpenAI-compatible Chat Completions endpoint,
   hosted or local (Ollama, LM Studio, …), a model ID, and an optional API key. **Test Connection**
   checks the values before you save.
3. **Try it.** Press ⌥⌘T in any text field.

Until setup is done, the menu bar menu shows **Finish Setting Up…**.

## Using Translate

- **⌥⌘T** opens the composer: one quiet line over the focused field, with the target language at
  its right edge. **Return** translates and replaces your
  selection, **Shift+Return** adds a line, **Esc** cancels and returns you to your app. Return
  confirms an input-method candidate first, and nothing is ever submitted in the target app.
- The **language pill** in the composer switches the target language. **Settings → Translate**
  accepts any language name, such as "formal Japanese".
- **Settings → Translate → Instructions** lets you rewrite what the model is told, for example to
  keep a casual tone, preserve product names, or always use British spelling. `{language}` is
  replaced with the target language. Your text is always sent separately as the user message.
  **Restore Default** brings back the built-in instructions.
- If a field can't be edited directly (some browsers and custom editors) or Accessibility is off,
  the composer opens in **copy mode** and the translation goes to your clipboard.
- If anything changes before pasting (you switched apps, edited the field, or moved the cursor),
  NyCopilot doesn't paste. The result goes to your clipboard and History, with a short note.
- Errors appear inline, and Return retries. Configuration errors offer an **Open Settings** button.
- **⌥⌘H** opens **History**: search, copy (Return, ⌘C, or double-click), and delete (⌫). Settings →
  Translate can clear all of it. Only translations are stored, never your source text.

## Using Window Layouts

Arrange the frontmost window with a shortcut, from **Window Layout** in the menu bar menu, or by
dragging it to the edge of the screen:

| Layout | Default shortcut |
| --- | --- |
| Left, right, top, or bottom half | ⌃⌥ ← → ↑ ↓ |
| Corners: top left, top right, bottom left, bottom right | ⌃⌥ U, I, J, K |
| First, center, or last third | ⌃⌥ D, F, G |
| First or last two thirds | ⌃⌥ E, T |
| Maximize, maximize height | ⌃⌥↩, ⌃⌥⇧↑ |
| Center, make larger, make smaller | ⌃⌥ C, =, − |
| Restore the size it had before NyCopilot moved it | ⌃⌥⌫ |
| Next or previous display | ⌃⌥⌘ → ← |

- Pressing the same layout again does what you choose in **Settings → Windows**: cycle a half's
  width (½ → ⅔ → ⅓, the default), move the window to the next display, or nothing. Moving keeps it
  travelling the way you pressed: a second Left Half lands in the right half of the display to the
  left. Corners and thirds travel the same way.
- Drag a window to the left or right edge for a half, to a corner for a quarter, to the top for
  maximize, or along the bottom for a third. A translucent preview shows where it will land.
- On a portrait display, thirds stack vertically.
- **Settings → Windows** turns drag snapping on or off, chooses the repeat behavior, sets a gap between
  windows, and lets you change any shortcut. Other window managers that use the same shortcuts
  (Rectangle, Magnet, Spectacle) should be quit first.
- **Switching from Rectangle:** the first time NyCopilot runs with Window Layouts, it imports the
  shortcuts you customized in Rectangle (unless you've already changed NyCopilot's) and its repeat
  behavior. Rectangle-only
  actions, such as Todo mode, are skipped. **Settings → Windows → Import** runs it again any time.

Every module's shortcuts can be changed or turned off in its own Settings tab. A shortcut needs ⌘,
⌥, or ⌃, or it can be a function key on its own, such as F2. On Apple keyboards, F-keys control
brightness and volume unless you hold fn or turn on "Use F1, F2, etc. keys as standard function
keys" in System Settings → Keyboard. **Settings → General**
shows the Accessibility status and an **Open at login** switch.

## Privacy and data

- Text is sent only when you press Return, and only to the endpoint you configured. There is no
  telemetry.
- Data lives in `~/Library/Application Support/NyCopilot/nycopilot.db` (folder 0700, file 0600).
  Deleting an item removes its text immediately and leaves a content-free tombstone for future sync.
- The API key is stored only in the macOS Keychain (`dev.nycopilot.NyCopilot`) and is passed to the
  core per request. It is never written to the database or to preferences.
- Model requests have strict bounds: 64 KiB of input, 1 MiB reply, 60 s total, no redirects, no
  retries, no caching. HTTP errors never expose the provider's response body.

## Coming from NyTranslate

On first launch, NyCopilot imports NyTranslate's endpoint, model, target language, shortcuts, and
history. The old history file is renamed to `history.sqlite3.imported`. The API key moves to the new
Keychain item the first time it's needed, which may show a one-time Keychain prompt. macOS treats
NyCopilot as a new app, so Accessibility must be granted again.

## Layout

```
crates/ny-core      records, settings, events, module registry, cancellation
crates/ny-llm       provider settings and Chat Completions client (`llm` module)
crates/ny-modules   module logic (`translate`)
crates/ny-ffi       C ABI (`include/ny_core.h`)
apps/macos          Swift package: NyCopilot app, MacPlatform helpers, tests, icon source
spec/               architecture, protocol, and module docs
```
