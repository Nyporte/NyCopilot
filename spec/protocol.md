# Core protocol

Clients call the core with a method name and a JSON object of parameters. The same methods are
available through the C ABI today and will be served over the network by `ny-server` later.

## Envelope

```json
{ "ok": <result> }
{ "error": { "code": "http_status", "message": "Access denied (HTTP 401). …", "status": 401 } }
```

`message` is safe to show to users and never contains user text, response bodies, or secrets.
Branch on `code`, not on `message`.

| Code | Meaning |
| --- | --- |
| `invalid_params` | Missing or malformed parameters, unknown collection. |
| `unknown_method` | No such namespace or command. |
| `invalid_setting` | Unknown key, wrong type, or rejected by the module's validator. |
| `not_found` | The record no longer exists. |
| `storage` | The database could not be read or written. |
| `cancelled` | The request was cancelled with `core.cancel`. |
| `provider_not_configured` | `llm.endpoint` or `llm.model` is empty. |
| `empty_input`, `input_too_large`, `invalid_key` | Request rejected before any network access. |
| `http_status` | Non-2xx reply; `status` holds the code. Never retried. |
| `network` | DNS, connection, TLS, or timeout failure. |
| `invalid_response`, `empty_response`, `response_too_large`, `truncated_response` | Unusable reply. |

## C ABI

```c
NyHandle *ny_open(const char *config_json, ny_event_callback on_event, void *context, char **error_out);
char     *ny_call(const NyHandle *handle, const char *method, const char *params_json);
void      ny_string_free(char *text);
void      ny_close(NyHandle *handle);
```

`config_json` is `{"data_dir": "<absolute path>", "platform": "macos"}`. Every returned string is
freed with `ny_string_free`. `ny_call` is thread-safe and blocks for the duration of the method.

## Built-in methods

| Method | Params | Result |
| --- | --- | --- |
| `core.info` | — | `{version, platform, device_id, revision, modules: [id]}` |
| `core.modules` | — | `[Manifest]` |
| `core.cancel` | `{request_id}` | `{cancelled: bool}` |
| `settings.get` | `{key}` | value (stored or manifest default; `null` for unset `client.*`) |
| `settings.set` | `{key, value}` | `{}`; type must match the default |
| `settings.reset` | `{key}` | `{}` |
| `settings.list` | `{prefix?}` | `{key: value}` including defaults |
| `records.list` | `{collection, before?, limit?=100, search?}` | `{records: [Record], next?}` newest first |
| `records.get` | `{id}` | `Record` |
| `records.delete` | `{id}` | `{deleted: bool}` (tombstone; deleting nothing changes nothing, including the revision) |
| `records.clear` | `{collection}` | `{deleted: count}` (an empty collection leaves the revision and emits no event) |
| `records.changes` | `{since?=0, limit?=100}` | `{records, revision}` including tombstones |

`Record` = `{id, collection, data, created_at, updated_at, deleted, origin, rev}` (times in Unix ms).

## Module methods

| Method | Params | Result |
| --- | --- | --- |
| `llm.complete` | `{system, user, api_key?}` | `{text}` |
| `llm.test` | `{endpoint, model, api_key?}` | `{elapsed_ms}` |
| `translate.run` | `{text, target_language?, api_key?, google_key?, volcengine_key?, request_id?, save?}` | `{text, target_language, engine, notice?, record}` — tries the engines in `translate.engine_order`, skipping any that are off, not set up, or don't offer the language; the next takes over when one fails. `engine` is `"google"`, `"volcengine"`, or `"model"`; `notice` names the engines that failed and why. Saved to `translate.history` before returning, unless `save` is `false` (then `record` is `null`; screen translation uses this) |
| `translate.test_google` | `{url, key?}` | `{text, elapsed_ms}` — translates a short sample through the web app |
| `translate.test_volcengine` | `{app_id?, key}` | `{text, elapsed_ms}` — translates a short sample with Volcengine credentials |
| `translate.languages` | — | `[{name, native, code}]` — suggested languages with their own names and badge codes |
| `translate.cycle` | `{step: 1 or -1}` | `{target_language, native, code}` — steps through the favorites and saves the result as the target |
| `translate.native_name` | `{language}` | `{native, code}` — own name (as given when unknown) and badge code (EN, 中, 日; a mentioned language's code, else two letters) |
| `translate.import_legacy` | `{path}` | `{imported}` — NyTranslate history |
| `windows.actions` | — | `[{id, title, group}]` in menu order |
| `windows.compute` | `{action, window, screen, repeat?}` | `{frame}` — `screen` is the usable area; `repeat` counts consecutive presses. With `windows.repeat = move_across_displays`, a repeated side layout returns `{frame: null, move: {direction, action}}`: apply `action` on the nearest display in `direction` |
| `windows.move_to_screen` | `{window, from, to}` | `{frame}` keeping relative position and size |
| `windows.snap_area` | `{point: {x, y}, screen}` | `{action, frame}` or nulls when the pointer isn't at an edge |

| `capture.palette` | — | `["#RRGGBB"]` annotation colors |
| `capture.file_name` | `{date: [y, m, d, H, M, S]}` | `{name}` from `capture.file_name` and `capture.format`, made safe for any file system |
| `capture.record` | `{region, display?, width, height, path?}` | `{record}` in `capture.history` |
| `capture.recent_regions` | `{limit?=20}` | distinct `[{x, y, w, h}]`, newest first |
| `clipboard.add` | `{text, app?, bundle_id?}` | `{record}` in `clipboard.items` — an earlier entry with the same text is removed, so it moves to the top — then the retention settings are applied; or `{record: null, skipped}` with `skipped` one of `off`, `ignored_app`, `empty`, `too_large` (over 256 KiB) |
| `clipboard.prune` | — | `{deleted}`: entries beyond `clipboard.max_items` or older than `clipboard.keep_days` are tombstoned |
| `inbox.add` | `{text?, image?, app?, source?}` | `{record}` in `inbox.notes`; needs text (up to 64 KiB) or an image; `image` is a client-kept file named `<uuid>.png`; `source` is `typed` (default), `selection`, or `screenshot` |
| `inbox.update` | `{id, text}` | `{record}`: the note's text replaced, its id, creation time, image, app, and source kept |
| `inbox.count` | — | `{count}` of notes waiting |

Window and capture rectangles are `{x, y, w, h}` in points with a top-left origin and y growing downward.

Settings declared by modules: `llm.endpoint`, `llm.model` (synced, `""`),
`translate.target_language` (synced, `"English"`), `translate.screen_language` (synced, `""`: the language
screen translation reads into; empty means the device's own), `translate.favorite_languages` (synced, 1–8
distinct names, default English, Simplified Chinese, Japanese), `translate.trim_whitespace` (synced,
`true`: trims leading and trailing whitespace from results), `translate.engine_order` (synced,
`["google", "volcengine", "model"]`; engines it omits are tried last), `translate.google_enabled`,
`translate.volcengine_enabled`, `translate.model_enabled` (synced, `true`), `translate.google_url` (synced, `""`: the
Apps Script web app's `/exec` URL), `translate.volcengine_app_id` (synced, `""`: only for old-console credentials), and `translate.instructions` (synced; the
system message for translations, at most 8,000 characters, where `{language}` is replaced with the
target language; `settings.reset` restores the built-in text), `windows.gap` (synced, `0`, 0–60
points), `windows.repeat` (synced, `"cycle_sizes"`, or `"move_across_displays"` or `"nothing"`), and
`windows.drag_snap` (synced, `true`), `capture.save_folder` (device, `""` = Pictures/NyCopilot),
`capture.format` (synced, `"png"` or `"jpg"`), `capture.file_name` (synced, pattern with `{date}`,
`{time}`, `{n}`), `capture.color` (synced, `#RRGGBB`), `capture.stroke` (synced, 1–24), `capture.style` (synced, an
object: `corner_radius` 0–64, `filled`, `font` family name or `""` for the system font, `text_size` 6–144, `bold`,
`italic`, `underline`, `strikethrough`; unknown keys are rejected), `capture.pin_shadow` (synced, `true`), `capture.hide_own_windows` (synced, `false`), `clipboard.enabled` (device, `true`), `clipboard.keep_days`
(synced, 1–365, `30`), `clipboard.max_items` (synced, 10–5000, `500`), and `clipboard.ignored_apps` (synced,
bundle identifiers; password managers by default).

## Events

Delivered through the `on_event` callback as JSON, on whichever thread made the change.

```json
{ "type": "records.changed", "collection": "translate.history", "id": "…", "change": "inserted" }
{ "type": "records.changed", "collection": "translate.history", "change": "cleared" }
{ "type": "settings.changed", "key": "translate.target_language" }
```

## Model requests

`llm.*` and model-backed module methods send one `POST` with `Content-Type: application/json`:
`{"model", "messages": [{"role": "system"}, {"role": "user"}], "stream": false}`. Input is limited
to 64 KiB of UTF-8, replies to 1 MiB. Timeouts: 15 s connect, 30 s waiting for a reply, 60 s total.
Redirects are refused, nothing is cached, and there are no retries. The reply must contain a
non-empty `choices[0].message.content`; `finish_reason: "length"` is rejected as truncated.
