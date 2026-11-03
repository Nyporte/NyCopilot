# Menu Bar, stage 2: a bar that shows the hidden icons

Status: **plan only**, not built. Stage 1 (the divider and chevron, `Modules/MenuBar`) ships first.

## Why

Stage 1 hides icons by pushing them past the left edge of the screen. "Show" brings them back into
the menu bar, which works while there's room. On a MacBook with a notch there often isn't: macOS
draws status items only right of the notch, and anything that doesn't fit stays out of sight even
when shown. Those icons are unreachable today, with or without NyCopilot. A small bar that drops
down under the menu bar and shows them would make them reachable on any display.

## What it would do

Clicking the chevron (or the shortcut) while **Show hidden icons in a bar** is on opens a panel
just under the menu bar, right-aligned under the chevron, with the hidden icons in a row as they
look in the menu bar. Clicking one opens its menu as if it had been clicked in the menu bar. The bar
closes on Esc, on a click elsewhere, or after the item's menu closes.

## Approach

1. **Find the hidden items.** `CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID)`; status
   items are windows at layer `kCGStatusWindowLevel` (25) owned by their app's process, with bounds
   but (without Screen Recording) no titles. Hidden ones are the ones whose frame lies left of the
   divider's window, so off screen while hidden. Order them by x. Name each by its owner
   (`kCGWindowOwnerName`, `kCGWindowOwnerPID`) for accessibility labels.
2. **Draw them.** While the items are off screen there are no pixels to capture, so the bar works
   in two steps, out of sight: show the icons (divider back to a line), capture each item's window
   with ScreenCaptureKit (`SCScreenshotManager.captureImage` with an `SCContentFilter` for that one
   `SCWindow`, which NyCopilot's Screen Recording permission already covers), then hide them again
   and show the images in the bar. The swap takes one frame each way; it can be hidden from view
   under the bar's own panel, the way F1 freezes the screen before acting. Captures are cached per
   item and refreshed each time the bar opens (icons change: a battery level, a sync badge).
   Without Screen Recording, the bar falls back to app icons (`NSRunningApplication.icon`) and names.
3. **Forward clicks.** A click on an image has to reach the real item, which is off screen:
   - Preferred: **Accessibility.** Each app's status items are `AXMenuBarItem`s under the app's
     `AXExtrasMenuBar` attribute (`kAXExtrasMenuBarAttribute`); `AXUIElementPerformAction(item,
     kAXPressAction)` opens its menu without moving anything. NyCopilot already has Accessibility.
     Match a bar image to its AX element by owner PID and order (and AX frame when on screen).
   - Fallback: **synthesized events.** Show the icons (out of sight, as above), post a
     `CGEvent` mouse down/up at the item's on-screen centre, and keep them shown while its menu is
     open; hide again when the menu closes (`NSMenu.didEndTrackingNotification` doesn't reach other
     apps' menus, so this needs the AX `AXMenuClosed` notification on that app, or the pointer
     leaving the menu). Used for items that don't expose an `AXExtrasMenuBar` (some Electron and
     Java apps).
4. **Where it lives.** A `HiddenItemsBar` panel (non-activating, `.statusBar` level, below the menu
   bar of the chevron's screen) and an `ItemFinder` (window list + AX lookup) in `Modules/MenuBar`.
   The core gets one setting, `menubar.show_in_bar` (device, `false`); nothing platform-specific
   goes into the core.

## Risks

- **Private-ish behaviour.** Nothing here uses private API, but it relies on how macOS lays out and
  layers status items (layer 25, one window per item, items left of a wide item pushed off screen).
  macOS 26 changed menu bar internals (Control Center hosts more items; Liquid Glass); each major
  macOS release needs re-checking. Stage 1 has the same dependency, in a smaller form.
- **Screen Recording prompts and indicator.** Capturing other apps' item windows uses
  ScreenCaptureKit; on macOS 15 and later that can raise the periodic "continue to allow" prompt and
  the purple indicator while capturing. Captures must be short single frames, never streams.
- **Visible flicker.** Showing and hiding the icons to capture or click them moves the whole right
  side of the menu bar for a frame. It must happen under a covering panel (as F1 does) or the
  feature will feel broken. Needs measuring on a 60 Hz external display and a 120 Hz ProMotion one.
- **Click forwarding gaps.** `AXPress` opens most status menus, but apps that draw their own popover
  on `mouseDown` (some Electron apps) may ignore it or open it at the item's off-screen position.
  Synthesized clicks need the item on screen, so they bring back the flicker problem and race with
  the user's own pointer.
- **Where menus open.** An item's menu or popover opens at the item's real position. Pressed while
  off screen, it may open at the left edge or not at all; the item may need to be shown first.
- **Matching images to items.** The window list has no stable identifiers across relaunches; owner
  PID plus order breaks when an app has several items or relaunches mid-session. Re-scan on
  `NSWorkspace.didLaunchApplicationNotification` / `didTerminateApplicationNotification`.
- **Performance.** Window-list scans and captures only when the bar opens, never on a timer.
- **Ordering across relaunches (stage 1, measured).** macOS saves an item's place
  (`NSStatusItem Preferred Position <name>` in its app's defaults) once items have been ⌘-dragged;
  before that there is none, and a new item lands leftmost. After the user's first drags, every item
  had one, NyCopilot's divider (362) and chevron (336) included, and the icons dragged left of the
  divider (538, 462, 390) stayed there through three NyCopilot relaunches. The saved value orders
  items rather than giving an exact distance from the right edge.
- **One item can't both hide and stay visible (measured).** Growing the chevron itself instead of a
  separate divider was tried: macOS cut the item to 5,016 pt, ending where NyCopilot's icon began,
  and drew none of it (`kCGWindowIsOnscreen` false), arrow included, so nothing was left to click.
  A status item is shown only if all of it fits, which is why the divider is a separate item.

## How to check it when built

- Unit tests for picking hidden items from a window list (frames left of the divider, ordering,
  several displays) and matching them to AX elements by PID and order.
- In the real app, on a notched MacBook and an external display: every hidden item appears in the
  bar, a click opens its own menu, the menu bar doesn't visibly jump, and no Screen Recording prompt
  appears beyond the existing permission. Log (Diagnostics) which path each click took: AX press or
  synthesized click, and whether the menu opened.
