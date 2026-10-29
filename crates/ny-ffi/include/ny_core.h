/*
 * NyCopilot core — C ABI.
 *
 * Every call takes a method name and JSON parameters and returns a JSON envelope:
 *   {"ok": <result>}  or  {"error": {"code": "...", "message": "...", "status": 429}}
 * Methods and event types are documented in spec/protocol.md.
 */
#ifndef NY_CORE_H
#define NY_CORE_H

#ifdef __cplusplus
extern "C" {
#endif

typedef struct NyHandle NyHandle;

/* Receives a JSON event; the string is valid only during the callback, which may run on any thread. */
typedef void (*ny_event_callback)(const char *event_json, void *context);

/* config_json: {"data_dir": "/path", "platform": "macos"}. Returns NULL on failure and, when
   error_out is non-NULL, stores an error envelope there (free with ny_string_free). */
NyHandle *ny_open(const char *config_json, ny_event_callback on_event, void *context, char **error_out);

/* Thread-safe. Blocks for the duration of the method; call model-backed methods off the UI thread.
   params_json may be NULL. The result must be freed with ny_string_free. */
char *ny_call(const NyHandle *handle, const char *method, const char *params_json);

void ny_string_free(char *text);

/* No calls may be in flight. */
void ny_close(NyHandle *handle);

#ifdef __cplusplus
}
#endif

#endif
