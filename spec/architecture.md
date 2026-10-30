# NyCopilot architecture

NyCopilot is meant to grow into a personal platform: a set of modules (translate, clipboard
history, screenshot & pin, window management, quick chat with an agent, kanban, …) that run on
several operating systems and, later, sync through a server. This document explains how the
pieces fit together and the rules that keep them portable.

## Layers

```
┌────────────────────────────────────────────────────────────────────────────┐
│ Native clients (apps/)                                                     │
│   macOS: Swift/AppKit   ·  Windows, Linux, mobile: later                   │
│   UI, global shortcuts, Accessibility / UI Automation, clipboard, capture, │
│   window control, secure credential storage                                │
├──────────────────────────────── ny_call(method, json) ─────────────────────┤
│ ny-ffi       C ABI: open / call / free / close + an event callback         │
├────────────────────────────────────────────────────────────────────────────┤
│ ny-modules   platform-neutral module logic (translate, windows, capture)   │
│ ny-llm       provider settings, bounded Chat Completions client            │
│ ny-core      records, settings, events, module registry, cancellation      │
└────────────────────────────────────────────────────────────────────────────┘
                       ▲ later: ny-server exposes the same methods over HTTP/WebSocket
```

**The core decides what; the client decides how.** Anything that is data, policy, or model
interaction lives in Rust and is written once. Anything that needs the operating system (drawing
a panel, registering a hotkey, reading the focused text field, pasting, capturing the screen,
moving windows, storing a secret) lives in the client.

## Why one JSON method protocol

Every client talks to the core through a single function, `ny_call(method, params_json)`, which
returns `{"ok": …}` or `{"error": {code, message, status?}}`. This keeps the boundary:

- **Stable.** Adding a module or a command never changes the ABI or regenerates bindings.
- **Language-agnostic.** Swift, C#, Kotlin, and C++ only need a C call and a JSON parser.
- **Network-ready.** A future server can expose the identical methods over HTTP, so a thin client
  (web, mobile) or a remote agent can use the same API as the desktop apps.

See [protocol.md](protocol.md) for the methods and events.

## Data model

All module data lives in one SQLite database per user profile (`nycopilot.db`, mode 0600, in the
platform's per-user application-data folder):

- **Records** — `{id, collection, data, created_at, updated_at, deleted, origin, rev}`.
  Ids are UUIDv7 (globally unique, time-ordered). `collection` is `<module>.<name>`.
  `data` is module-defined JSON. Deletes leave content-free tombstones.
- **Settings** — typed JSON values declared in module manifests with defaults and a **scope**:
  `synced` (follows the user: provider, target language) or `device` (this machine only:
  shortcuts, window positions, onboarding state under the reserved `client.` prefix).
- **Revisions** — every write bumps a per-database counter and stamps the record with it and the
  device id. `records.changes {since}` returns everything changed after a revision, which is the
  primitive a sync server needs. Conflict policy (last-writer-wins per record) is the planned
  default; it is not implemented yet because there is no server yet.

Secrets are never stored in the database. Clients keep them in the platform's credential store
(Keychain, Windows Credential Manager, Secret Service) and pass them per call (`api_key`,
`google_key`, `volcengine_key`).

## Modules

A module has two halves:

1. **Core module** (Rust, `crates/ny-modules`): implements `ny_core::Module` — a `Manifest`
   (id, name, required capabilities, collections, settings, commands) plus a `call` handler and
   setting validation. It has no UI and no OS calls.
2. **Client shell** (per platform, e.g. `apps/macos/Sources/NyCopilot/Modules`): menu items,
   global shortcuts, windows, and whatever OS capabilities the manifest lists.

Clients read `core.modules` and load only shells whose core module exists and whose
capabilities they can provide. A server, for example, would host Chat or Kanban but never
Screenshot. See [modules.md](modules.md) for how planned modules split.

## Concurrency and cancellation

`Core` is thread-safe. The database lock is held only for individual store operations, never
across network requests. Model-backed methods block their caller, so clients call them off the UI
thread. A long call may carry a `request_id`; `core.cancel {request_id}` marks it cancelled and
the module discards its result before committing anything (a cancelled translation never reaches
history). HTTP requests cannot be aborted mid-flight and are bounded by timeouts instead.

## Repository layout

```
Cargo.toml              Rust workspace
crates/ny-core          records, settings, events, registry
crates/ny-llm           model provider + Chat Completions client (the `llm` module)
crates/ny-modules       module logic; `all()` lists what this build ships
crates/ny-ffi           C ABI + include/ny_core.h
apps/macos              Swift package: AppKit shell, MacPlatform helpers, tests
spec/                   these documents
Makefile                make build | test | run | icon | clean
```
