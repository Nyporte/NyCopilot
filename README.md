# NyCopilot

NyCopilot is a personal copilot that lives in the menu bar and works inside every app. It is a
foundation for many modules across several operating systems, with a sync server to come. Today it
ships three:

- **Translate** — type in any text field and replace it with a translation (⌥⌘T).
- **Window Layouts** — snap windows into halves, corners, and thirds by shortcut or by dragging.
- **Screenshot & Pin** — capture, annotate, copy, save, and pin images on top of everything (F1, F3).

## How it's built

- **A shared Rust core** (`crates/`) owns data, settings, modules, and model access: one SQLite
  database of sync-ready records, typed settings with defaults and validation, and a module registry.
- **Thin native clients** (`apps/`) own everything that needs the operating system. The macOS client
  is Swift/AppKit: menu bar, global shortcuts, Accessibility, screen capture, overlays, and Keychain.
- **One protocol.** Clients call the core with `ny_call(method, json)`. A future server will expose
  the same methods over the network.

See [spec/architecture.md](spec/architecture.md), [spec/protocol.md](spec/protocol.md), and
[spec/modules.md](spec/modules.md).

## Build and run

Requires macOS 13+, Xcode or Command Line Tools (Swift 5.9+), and Rust (stable, via rustup).

```sh
make build   # Rust core (release) + Swift app → dist/NyCopilot.app, signed
make run     # build and open
make test    # Rust tests (incl. loopback HTTP) + Swift tests; no permissions, no real API
```

Builds are signed with your Developer ID Application certificate (or Apple Development if that's all
you have) with the hardened runtime. macOS ties Accessibility, Screen Recording, and Keychain access to
that identity, so grants survive rebuilds. Without a certificate the build falls back to an ad-hoc
signature, prints a warning, and loses those grants on every rebuild. Choose a certificate with
`make build SIGN_IDENTITY='…'`. Notarize before sharing the app.

## First run

A short guide opens on first launch:

1. **Allow Accessibility**, which Translate and Window Layouts use to read fields, paste, and move
   windows.
2. **Connect a translator.** Settings → Model takes any OpenAI-compatible Chat Completions endpoint,
   hosted or local (Ollama, LM Studio…), a model ID, and an optional API key; **Test Connection** checks
   it. Or set up **Google Translate** or **Volcengine** in Settings → Translate (below). Any one is
   enough; with several, they back each other up.
3. **Try it.** Press ⌥⌘T in any text field.

Screenshot & Pin asks for **Screen Recording** the first time you capture. Until setup is done, the
menu bar menu shows **Finish Setting Up…**.

## Translate

- **⌥⌘T** opens the composer at your text cursor. A small badge at its right edge shows the target
  language (EN, 中, 日…). **Tab** and **Shift+Tab** step through your favorite languages; the choice
  is remembered. **Return** translates and replaces your selection, **Shift+Return** adds a line,
  **Esc** cancels. Return confirms an input-method candidate first; nothing is submitted in your app.
- If the field can't be edited directly, or Accessibility is off, the composer works in **copy mode**
  and puts the translation on your clipboard. If anything changes before pasting (you switched apps,
  edited the field, moved the cursor), NyCopilot doesn't paste; the result goes to your clipboard and
  History with a short note.
- **Engines** (Settings → Translate) lists the translation services in the order they're tried —
  Google Translate, Volcengine, then the model by default. ▲ ▼ reorder them and each has a switch.
  A translation goes to the first engine that's on and set up; when it fails, or doesn't offer the
  language, the next one takes over and a short note says which failed and why. Only the model
  follows the instructions, and only the model handles qualified languages such as "formal Japanese".
  - **Google Translate** runs through your own Apps Script web app, which receives
    `{key, text, source: "auto", target}` as a POST body and answers with `{code, translated}`. Deploy
    it with **Execute as: Me** and **Who has access: Anyone**; any other access setting sends requests
    to Google's sign-in page, so the script never runs.
  - **Volcengine** is Doubao's machine translation (32 languages). Paste an API key from the new
    console, or an App ID and access token from the old one. Each line is translated separately, so
    line breaks and indentation come back exactly.
  - **Test** in each section translates a sample with the values on screen, before you save.
- **Hold ⌥⌘T** (the translate shortcut — a tap still opens the composer) to translate what's on
  screen. Like Live Text, the screen dims a little and the text on every display glows, a paragraph's
  lines as one shape —
  the page itself stays exactly as it is. Point at a block that isn't in your language and its lines
  are outlined and a card with its translation floats just below it. Lines wrapped from one paragraph are one block, so sentences are
  translated whole; sidebar labels, list items, and headings are their own blocks. Text is read on
  your Mac; only a block you rest the pointer on is sent for translation (nothing is spent on text you
  don't look at), and each is translated once a session, so coming back to it is instant.
  You keep using the computer as usual: clicks and scrolling go straight through. It keeps up as the
  screen changes: highlights disappear the moment what's under them changes, and once things settle,
  only the changed part is read again. A glow around the screen edges and a pill at the bottom show it's on; **Esc** ends it
  (or hold the shortcut again, or **Translate Screen** in the menu bar menu).
- **⌥⌘H** opens **History**: search, copy (Return, ⌘C, double-click), delete (⌫). Only translations
  are stored, never your source text.
- **Settings → Translate**
  - **Favorite Languages** — the languages Tab steps through (up to 8): ▲ ▼ to reorder, − to remove,
    **Add Language** to pick one or type any name, such as "Brazilian Portuguese" or "formal Japanese".
  - **Trim spaces and line breaks** (on by default) — removes whitespace a model adds at the start or
    end; line breaks inside are kept.
  - **Instructions** — what the model is told; `{language}` becomes the target language. Your text is
    always sent separately. **Restore Default** brings back the built-in instructions.

## Window Layouts

Arrange the frontmost window with a shortcut, from **Window Layout** in the menu bar menu, or by
dragging it to the edge of the screen.

| Layout | Default shortcut |
| --- | --- |
| Left, right, top, or bottom half | ⌃⌥ ← → ↑ ↓ |
| Top left, top right, bottom left, bottom right | ⌃⌥ U, I, J, K |
| First, center, or last third | ⌃⌥ D, F, G |
| First or last two thirds | ⌃⌥ E, T |
| Maximize, maximize height | ⌃⌥↩, ⌃⌥⇧↑ |
| Center, make larger, make smaller | ⌃⌥ C, =, − |
| Restore the size it had before NyCopilot moved it | ⌃⌥⌫ |
| Next or previous display | ⌃⌥⌘ → ← |

- Pressing the same layout again does what you choose in **Settings → Windows**: cycle a half's width
  (½ → ⅔ → ⅓), move to the next display in that direction, or nothing.
- Drag a window to a side for a half, a corner for a quarter, the top to maximize, or along the bottom
  for a third. A translucent preview shows where it will land. Thirds stack on portrait displays.
- **Switching from Rectangle:** on first run NyCopilot imports the shortcuts you customized in
  Rectangle and its repeat behavior; **Settings → Windows → Import** runs it again. Quit other window
  managers that use the same shortcuts.

## Screenshot & Pin

**F1** freezes your screens for capturing:

- **Select** by dragging, or hover a window, menu, or the Dock and click to take it exactly. Drag the
  selection or its handles to adjust; arrows nudge it by a point and ⇧ arrows resize it; ⌘A takes the
  whole screen; `,` and `.` recall regions you captured before.
- **Inspect** with the magnifier: a pixel grid around the pointer, its position in pixels, the size
  of the selection while you drag, and the color in HEX and RGB. **C** copies the color without ending
  the capture; **Shift** switches between `#RRGGBB` and `r, g, b`.
- **Annotate** with rectangle, ellipse, arrow, line, pen, highlighter, mosaic, and text (keys 1–8).
  Each tool shows its own options under the toolbar: eight colors, line width (1–24), corner radius
  for rectangles, outline or filled for rectangles and ellipses, and font, size, **bold**, *italic*,
  underline, and strikethrough for text. Text: **Return** places it, **Shift+Return** adds a line,
  **Esc** discards. Options are remembered; ⌘Z and ⇧⌘Z undo and redo.
- **Select text in place** with **T** (or the text button). The selection turns into macOS Live
  Text: every word glows where it is on screen, and you drag across it to select, as in Preview. **⌘C**
  copies what you selected; **T** again (**Copy All**, or Return) copies everything and closes the capture; **Esc**
  goes back to the toolbar. Recognition starts on its own as soon as you settle on a selection, on
  your Mac and offline, so T is instant; the button lights up when there's text. It reads the screen
  as it was, so your annotations don't get in the way.
- **Scrolling capture** with **S** (or the tall-rectangle button). The selection stays outlined;
  scroll the page, document, or chat under it — down, up, or both, starting anywhere — and a panel
  beside it shows the whole image so far, shrinking to fit as it grows. Behind the scenes NyCopilot
  watches the entire scroll area around the selection (found through Accessibility, or else the
  window), so even a fast scroll is placed exactly and rows that rushed past the selection are read
  from elsewhere in the area; only your selection ends up in the image. Things in that area that
  change on their own — a blinking caret, a hover highlight, video, a header sliding in — don't throw
  it off: a frame is placed where most of the content agrees, and "nothing moved" competes on equal
  terms. If a scroll is ever too big to fill, scrolling back a little fills the gap. Toolbars and
  sticky headers appear once. Its keys
  work wherever the focus is: **Return** (copy), **⌘S**, **⇧⌘S**, **⌘T** (pinned to fit the screen),
  or **Esc** to cancel. Up to 30,000 pixels tall; NyCopilot's own windows are never in the picture.
- **Finish** with **Return** or ⌘C to copy, **⌘T** to pin, **⌘S** to save with a dialog, **⇧⌘S** to save
  straight to your folder, or **Esc** (or right-click) to cancel.

**F3** pins whatever is on the clipboard: an image as is, a `#RRGGBB` color as a swatch, other text as
a card. **⇧F3** hides or shows all pins. A faint blue border fades in while the pointer is over a pin
and turns solid when you click it. On a pin: drag to move, scroll to zoom, ⌥-scroll for opacity,
**1–4** to rotate and flip, **T** to select its text in place (T again copies it all), **0** for actual size, ⌘C to copy, ⌘S to save, **Esc** or a double-click to
close. Right-click for opacity, shadow, click-through, and **Close All Pins**; **Make Pins Clickable**
in the menu bar menu brings click-through pins back.

**Settings → Screenshot** sets the save folder (Pictures/NyCopilot by default), PNG or JPEG, a
file name pattern with `{date}`, `{time}`, and `{n}`, pin shadows, and the shortcuts. **Hide NyCopilot
windows** (off by default) leaves pins and other NyCopilot windows out of captures.

## Shortcuts

Every module lists its shortcuts in its own Settings tab. A shortcut needs ⌘, ⌥, or ⌃, or can be a
function key on its own (F1, F2…). On Apple keyboards the F-keys control brightness and volume unless
you hold fn or turn on "Use F1, F2, etc. keys as standard function keys" in System Settings →
Keyboard. **Settings → General** shows the Accessibility status and an **Open at login** switch.

## Privacy and data

- Text recognition is macOS Live Text (VisionKit) and runs entirely on your Mac; nothing is uploaded.
- Text is sent only when you press Return in Translate, and only to the services you configured
  (the first engine that succeeds, in your order). There
  is no telemetry. Screenshots never leave your Mac.
- Data lives in `~/Library/Application Support/NyCopilot/nycopilot.db` (folder 0700, file 0600):
  settings, translation history, and capture history (regions and file paths, not images). Deleting
  an item removes its content immediately and leaves a content-free tombstone for future sync.
- The model's API key, the Google web app's access key, and the Volcengine key are stored only in the
  macOS Keychain (`dev.nycopilot.NyCopilot`) and passed to the core per request; they are never written
  to the database or to preferences, and never put in a URL.
- Requests are bounded: 64 KiB of input, 1 MiB reply, 60 s total, no retries, no caching. Model
  and Volcengine requests follow no redirects; Google requests follow exactly one, to `script.googleusercontent.com`,
  as a plain GET without the key. HTTP errors never expose the server's response body.

## Coming from NyTranslate

On first launch NyCopilot imports NyTranslate's endpoint, model, target language, shortcuts, and
history (the old file is renamed `history.sqlite3.imported`). The API key moves to the new Keychain
item the first time it's needed, which may show a one-time Keychain prompt.

## Layout

```
crates/ny-core      records, settings, events, module registry, cancellation
crates/ny-llm       provider settings and Chat Completions client (`llm` module)
crates/ny-modules   module logic: translate, windows, capture
crates/ny-ffi       C ABI (`include/ny_core.h`)
apps/macos          Swift package: NyCopilot app (App, System, Interface, Modules/<module>),
                    MacPlatform helpers, tests, icon source
spec/               architecture, protocol, and module docs
```
