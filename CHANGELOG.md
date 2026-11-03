# Changelog

What's new in each version of NyCopilot. Versions follow [Semantic Versioning](https://semver.org);
how releases are made is in [docs/RELEASING.md](docs/RELEASING.md).

## Unreleased

- **Tidy the menu bar.** Settings → Menu Bar puts an arrow in the menu bar: ⌘-drag the icons you
  rarely need left of it, and a click on the arrow hides them (or shows them again). They can hide
  again on their own after a few seconds, stay hidden across restarts, and can have a shortcut.
  It's off until you turn it on.
- **Hidden icons in a bar.** With Settings → Menu Bar → Show hidden icons in a bar, the arrow opens
  the hidden icons in a row under the menu bar instead of making room for them in it. Click one to
  open its menu; the icons show in the menu bar while it's open and hide again when it closes.

## 0.5.0 — 2026-11-03

- **F4 asks AI.** Ask AI joins the other one-press keys: F1 captures, F2 translates, F3 jots, F4
  asks. With ⌥⌘ letters it stays ⌥⌘A, and a shortcut you set yourself stays yours.
- **Mouse speed and acceleration.** Settings → Mouse makes a mouse faster than System Settings
  allows (up to 8×), sets how much acceleration it has, or turns acceleration off: drag, or type
  the number. The trackpad is left alone, and mice go back to System Settings when it's off or
  NyCopilot quits.
- **Reverse the scroll wheel.** A mouse wheel can scroll the Windows way while the trackpad keeps
  natural scrolling.
- **Smooth scrolling.** Each wheel click glides, like Mos, over a distance and time you choose,
  with ⇧ for sideways and ⌥ for faster; games and remote desktops can be left as they are.

### New

- Set mouse speed and acceleration, and reverse or smooth the scroll wheel (#11)
- F4 asks AI, and a new opening picture for the README (#10)

## 0.4.1 — 2026-11-01

- **No more stuck recording indicator.** When the disk is nearly full, macOS's screen capture service
  could keep a scrolling capture or GIF recording running after it ended, with its indicator on.
  NyCopilot now restarts the service and ends it.
- **Smaller GIFs.** Recordings with movement in several places come out smaller, and white stays
  pure white.

### Fixed

- Restart the capture service when a stream won't stop (#6)

### Faster

- Leave unchanged pixels transparent (#4)

## 0.4.0 — 2026-11-01

The first public release.

- **Ten languages.** English, 简体中文, 繁體中文, 日本語, 한국어, Español, Français, Deutsch,
  Português (Brasil), and Русский, with a language picker in Settings → General.
- **A steadier capture.** The crosshair is there from the first moment of F1 and stays put, whatever
  app is behind it; the app you were in never flickers when the capture ends.
- **A toolbar that answers the pointer.** Icons brighten under the pointer and dim when pressed,
  and the OCR button lights up when the selection has text in it.
- **F2 translates.** Capture, translate, and the Inbox are now F1, F2, and F3: one press each. (With
  ⌥⌘ letters, Translate stays ⌥⌘T.)
- **Translate's favorites follow your Mac.** On a Mac in another language, Tab steps between
  English and yours from the start.

### New

- F2 translates by default (#1)
- Send Feedback opens a bug report with the versions filled in

