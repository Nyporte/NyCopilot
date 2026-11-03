<div align="center">

<img src="docs/images/icon.png" width="128" alt="NyCopilot icon">

# NyCopilot

### The copilot that lives in every app on your Mac.

Translate what you write and read. Capture and mark up anything on screen. Ask AI about it.<br>
Keep the thought for later. All of it one keystroke away, right where you're working.

[**Download for macOS**](https://github.com/Nyporte/NyCopilot/releases/latest) · [User guide](docs/GUIDE.md) · [What's new](CHANGELOG.md)

![macOS 14+](https://img.shields.io/badge/macOS-14%2B-111?logo=apple)
![Free and open source](https://img.shields.io/badge/license-MIT-2ea44f)
![10 languages](https://img.shields.io/badge/interface-10%20languages-5e5ce6)
[![CI](https://github.com/Nyporte/NyCopilot/actions/workflows/ci.yml/badge.svg)](https://github.com/Nyporte/NyCopilot/actions/workflows/ci.yml)

<img src="docs/images/demo-hero.gif" width="760" alt="F1: drag out a chart, P pins it, and it stays on top over the slides being made. F2: type a reply in English, Return, and it goes out in Japanese. F3: jot a to-do from a web page into the inbox. F4: select a paragraph, Summarize, and the summary streams in. Control-Option-Right: drag one window to the left edge and send the other to the right half. Then every key on one card">

</div>

---

## Stop switching apps to get small things done

You're reading a page in another language, and you open a translator. You want to show someone a
detail, and you open a screenshot tool, then an editor, then a chat. You want to know what a
paragraph means, and you open a chatbot and paste it in. You have an idea mid-meeting, and you open
a notes app, and by the time it's open the idea is gone.

**NyCopilot does all of that where you already are.** It sits quietly in your menu bar and wakes up
on a keystroke, over whatever app you're in, then gets out of the way.

- **One keystroke, no detours.** F1 captures, F2 translates, F3 jots a note, F4 asks AI. Nothing
  to open, nothing to switch to.
- **One capture, many next steps.** Whatever you're looking at, whether a screenshot, a pinned
  image, a clipboard entry or a note, answers the same keys: **R** translates it, **A** asks AI
  about it, **I** keeps it in your Inbox, **P** pins it to the screen.
- **Yours, and private.** No account and no telemetry. Text recognition runs on your Mac, your
  history stays on your Mac, and your keys live in the macOS Keychain.

## Screenshot & Pin: capture anything, then do something with it

Press **F1**. The screen freezes and NyCopilot outlines the window or element under your pointer:
click to take it, or drag any region. Then:

- **Mark it up**: rectangles, ellipses, arrows, lines, pen, highlighter, mosaic, and text, in your colors.
- **Read the text in it**: select and copy text right in the image. The OCR button lights up when
  there's text to find.
- **Go long or go live**: scroll to capture a whole page, or record the region as a GIF.
- **Pin it**: keep the image floating above everything while you work, zoom it, make it click-through.
- **Hand it on**: copy, save, translate the text in it, ask AI about it, or drop it in your Inbox.

The app you were in never flickers or loses its place. When you're done, you're right back where you were.

<img src="docs/images/demo-capture-edit.gif" width="760" alt="F1 over an invoice: a box around the total, an arrow to the due date labelled Pay by Friday, mosaic over the contact details, P pins it. Over in a spreadsheet, the pin scrolls smaller and fades a little, moves beside the sheet, and the amount is typed in from it">

<img src="docs/images/demo-capture-modes.gif" width="760" alt="Three captures at once. T turns a shared slide's words into text: one line is selected and copied. S and scrolling stitches a whole article together in the panel beside it. G and Record captures a sync animation, and the GIF plays back ready to copy">

## Translate: write in any language, read everything in yours

- **Translate as you type.** Press **F2** in any text field, type in your language, press Return:
  the field gets the translation. Tab switches between your favorite target languages.
- **Translate a selection.** Select text on a page, in a PDF or a message, tap F2, and the
  translation appears on a card right beside it.
- **Translate the whole screen.** Hold F2 and every block of text on screen lights up. Point at
  one to read it in your language.

<img src="docs/images/demo-translate.gif" width="720" alt="Select a Japanese message and press F2: an English card appears. Press F2 in the reply field, type in English, press Return: it goes out in Japanese">

Works with macOS's own on-device translation out of the box, or with Google Translate, Volcengine,
or any AI model you connect, which can follow your style instructions ("formal Japanese", anyone?).

## Ask AI: explain, summarize, rewrite, right where you read

<img src="docs/images/demo-ask.gif" width="720" alt="Select a paragraph, press F4, click Summarize: the summary streams in beside the text">

Select a paragraph, a word or a screenshot and press **F4** (or **A** on a capture). Explain,
Summarize and Rewrite are one click away; anything else, just ask, and keep the conversation going.
Answers stream in as they're written, in your language, and a rewrite can replace your selection
in place.

**Bring your own model.** NyCopilot works with any OpenAI-compatible endpoint: a hosted provider,
or a model running on your own Mac with Ollama or LM Studio, fully offline.

## Inbox: catch the thought, deal with it later

<img src="docs/images/inbox.png" width="680" alt="The Inbox with notes from Safari, Notes, and Slack">

Press **F3** to jot a thought in a one-line bar that disappears as soon as you press Return. Or
select text in any app and press F3 to keep it, along with where it came from. Screenshots go in
with **I**.

Later, work through it with the keyboard: **Space** marks done, **L** snoozes it until tonight or
next week, and **S** sends it to Reminders, Apple Notes, or a Markdown folder (an Obsidian vault
works beautifully).

## Clipboard: everything you copied, one keystroke back

<img src="docs/images/clipboard.png" width="420" align="right" alt="Clipboard history with text, a link, a color, and an image">

Press **⌥⌘V** to see everything you've copied, text and images, newest first. Type to search,
press Return to paste it into the app you were in, or **⌘1–9** for the first nine. Pin the ones you
reuse every day.

Passwords and anything apps mark as private are never kept. Copies from password managers are
skipped too.

<br clear="right">

## Window Layouts: halves, thirds, corners, one shortcut each

Snap the front window to a half, a third, two thirds, a corner, or the next display with a
shortcut, or drag it to a screen edge. Coming from Rectangle? Import your shortcuts in one click.

## Menu Bar: hide the icons you rarely need

Turn it on in Settings → Menu Bar and an arrow joins your menu bar. ⌘-drag the icons you rarely
need to the left of it; click the arrow and they're gone, click again and they're back. They can
hide again on their own after a few seconds, and stay hidden across restarts. Or have the arrow
open them in a bar under the menu bar, and click one there to open its menu.

## Clock: another time zone in the menu bar

Keep the time where your team is in the menu bar: "Tue 4 Nov 14:05 · Tokyo", with or without the
date or seconds, in 12 or 24 hours, named by city, abbreviation, offset, or a name of your own. Click
it for more zones with their times and hours from you; click one to show it instead. It changes on
the minute (or second), right on time, and keeps up when your Mac wakes or travels.

## Every key, one press away

<img src="docs/images/keys.png" width="520" alt="The keys sheet for screenshots">

You don't need to memorize anything. Press **?** in any NyCopilot panel to see its keys, or
**⌥⌘/** for every shortcut you've set. Tips show up a couple of times, at the moment they help,
then never again.

## Speaks your language

NyCopilot's interface is in **English, 简体中文, 繁體中文, 日本語, 한국어, Español, Français,
Deutsch, Português (Brasil), and Русский**. It follows your Mac, or pick one in Settings → General.

## Private by design

- **No account, no telemetry, no analytics.** NyCopilot doesn't phone home.
- **On your Mac.** Text recognition uses macOS Live Text, on device. Clipboard history, notes,
  screenshots and translation history stay in a private folder in your Library.
- **Only what you send, only where you send it.** Text goes to a translation service or AI model
  only when you ask, and only to the ones you set up. A screenshot goes to a model only when you
  press A on it.
- **Keys in the Keychain.** API keys are stored in the macOS Keychain and never written anywhere else.

## Get started

1. **[Download the latest release](https://github.com/Nyporte/NyCopilot/releases/latest)**,
   unzip it, and move **NyCopilot** to Applications. It's signed and notarized by Apple.
2. **Open it.** A short guide asks what you want help with and sets up the shortcuts: F-keys or
   ⌥⌘ letters, whichever suits your keyboard (F1 · F2 · F3 · F4, or ⌥⌘S · ⌥⌘T · ⌥⌘J · ⌥⌘A).
3. **Allow Accessibility** when asked, so NyCopilot can read selections and paste results. The first
   capture asks for Screen Recording.

Everything else is optional. Translation works through macOS right away; connect an AI model in
Settings → AI & Engines whenever you like.

**Requirements:** macOS 14 Sonoma or later, on a Mac with Apple silicon.

## Questions

**Is it free?** Yes, free and open source under the MIT license. If you use an AI provider, you pay
them directly, or run a local model for free.

**Do I need an AI subscription?** No. Screenshots, the Inbox, clipboard history, window layouts and
on-device translation all work without one. AI adds Ask AI, screen translation, and translations
that follow your instructions.

**Will it slow my Mac down?** NyCopilot is a native app with a Rust core, idle in the menu bar
until you press a key.

**I found a bug, or I have an idea.** Choose **Send Feedback…** in the NyCopilot menu, or
[open an issue](https://github.com/Nyporte/NyCopilot/issues/new/choose). Bug reports come with
Diagnostics: what the app did lately, never your text.

## Under the hood

NyCopilot is a native Swift/AppKit app on a shared Rust core that owns data, settings and model
access, built so more platforms can follow. Want to build it, read the architecture, or contribute?

- [Build from source and how it's made](docs/GUIDE.md#how-its-built)
- [Contributing: branches, commits, checks, and releases](CONTRIBUTING.md)
- [Architecture](spec/architecture.md) · [Protocol](spec/protocol.md) · [Modules](spec/modules.md)

## License

[MIT](LICENSE) © Nyporte
