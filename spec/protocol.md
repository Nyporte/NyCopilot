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
| `records.delete` | `{id}` | `{deleted: bool}` (tombstone) |
| `records.clear` | `{collection}` | `{deleted: count}` |
| `records.changes` | `{since?=0, limit?=100}` | `{records, revision}` including tombstones |

`Record` = `{id, collection, data, created_at, updated_at, deleted, origin, rev}` (times in Unix ms).

## Module methods

| Method | Params | Result |
| --- | --- | --- |
| `llm.complete` | `{system, user, api_key?}` | `{text}` |
| `llm.test` | `{endpoint, model, api_key?}` | `{elapsed_ms}` |
| `translate.run` | `{text, target_language?, api_key?, request_id?}` | `{text, target_language, record}` — saved to `translate.history` before returning |
| `translate.languages` | — | `[{name, native, code}]` — suggested languages with their own names and badge codes |
| `translate.cycle` | `{step: 1 or -1}` | `{target_language, native, code}` — steps through the favorites and saves the result as the target |
| `translate.native_name` | `{language}` | `{native, code}` — own name (as given when unknown) and badge code (EN, 中, 日; a mentioned language's code, else two letters) |
| `translate.import_legacy` | `{path}` | `{imported}` — NyTranslate history |
| `windows.actions` | — | `[{id, title, group}]` in menu order |
| `windows.compute` | `{action, window, screen, repeat?}` | `{frame}` — `screen` is the usable area; `repeat` counts consecutive presses. With `windows.repeat = move_across_displays`, a repeated side layout returns `{frame: null, move: {direction, action}}`: apply `action` on the nearest display in `direction` |
| `windows.move_to_screen` | `{window, from, to}` | `{frame}` keeping relative position and size |
| `windows.snap_area` | `{point: {x, y}, screen}` | `{action, frame}` or nulls when the pointer isn't at an edge |

Window rectangles are `{x, y, w, h}` in points with a top-left origin and y growing downward.

Settings declared by modules: `llm.endpoint`, `llm.model` (synced, `""`),
`translate.target_language` (synced, `"English"`), `translate.favorite_languages` (synced, 1–8
distinct names, default English, Simplified Chinese, Japanese), and `translate.instructions` (synced; the
system message for translations, at most 8,000 characters, where `{language}` is replaced with the
target language; `settings.reset` restores the built-in text), `windows.gap` (synced, `0`, 0–60
points), `windows.repeat` (synced, `"cycle_sizes"`, or `"move_across_displays"` or `"nothing"`), and
`windows.drag_snap` (synced, `true`).

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
