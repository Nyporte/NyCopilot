//! The C ABI every native client links against.
//!
//! The whole surface is four functions. Calls take a method name and JSON parameters and return
//! a JSON envelope — `{"ok": <result>}` or `{"error": {"code", "message", "status"?}}` — so new
//! modules and methods never change the ABI. A future server exposes the identical protocol
//! over the network. See `spec/protocol.md` and `include/ny_core.h`.

use std::ffi::{c_char, c_void, CStr, CString};
use std::path::PathBuf;
use std::ptr;

use ny_core::{Core, NyError, Store};
use serde_json::{json, Value};

/// Called with a NUL-terminated JSON event. The string is only valid during the call.
pub type EventCallback = Option<extern "C" fn(event_json: *const c_char, context: *mut c_void)>;

/// Opaque handle owned by the client; release with `ny_close`.
pub struct NyHandle { core: Core }

struct SendPtr(*mut c_void);
unsafe impl Send for SendPtr {}
unsafe impl Sync for SendPtr {}

/// Assemble a core with every bundled module. Shared with tests and, later, the server binary.
pub fn open_core(data_dir: PathBuf, platform: &str, events: ny_core::EventSink) -> ny_core::Result<Core> {
    let store = Store::open(&data_dir.join("nycopilot.db"))?;
    Core::new(store, ny_modules::all(), platform, events)
}

/// Open the core. `config_json` is `{"data_dir": "...", "platform": "macos"}`.
/// Returns null on failure and, if `error_out` is non-null, stores an error JSON string there
/// (free it with `ny_string_free`).
///
/// # Safety
/// `config_json` must be a valid NUL-terminated string; `context` must stay valid until `ny_close`.
#[no_mangle]
pub unsafe extern "C" fn ny_open(config_json: *const c_char, on_event: EventCallback, context: *mut c_void,
                                 error_out: *mut *mut c_char) -> *mut NyHandle {
    let result = (|| {
        let config: Value = serde_json::from_str(&read(config_json)?)?;
        let data_dir = config["data_dir"].as_str().filter(|s| !s.is_empty())
            .ok_or_else(|| NyError::invalid_params("data_dir is required."))?;
        let platform = config["platform"].as_str().unwrap_or("unknown").to_string();
        let context = SendPtr(context);
        let events: ny_core::EventSink = Box::new(move |event: Value| {
            let context = &context;
            if let (Some(callback), Ok(text)) = (on_event, CString::new(event.to_string())) {
                callback(text.as_ptr(), context.0);
            }
        });
        open_core(PathBuf::from(data_dir), &platform, events)
    })();
    match result {
        Ok(core) => Box::into_raw(Box::new(NyHandle { core })),
        Err(error) => {
            if !error_out.is_null() { *error_out = into_c(json!({ "error": error })); }
            ptr::null_mut()
        }
    }
}

/// Run one method. Always returns a JSON envelope; free it with `ny_string_free`.
/// Safe to call from any thread, concurrently. Long calls (model requests) block the caller,
/// so clients call from a background thread.
///
/// # Safety
/// `handle` must come from `ny_open`; strings must be NUL-terminated (`params_json` may be null).
#[no_mangle]
pub unsafe extern "C" fn ny_call(handle: *const NyHandle, method: *const c_char, params_json: *const c_char) -> *mut c_char {
    let result = (|| {
        let handle = handle.as_ref().ok_or_else(|| NyError::invalid_params("The core is not open."))?;
        let method = read(method)?;
        let params = if params_json.is_null() { Value::Null } else { serde_json::from_str(&read(params_json)?)? };
        handle.core.call(&method, params)
    })();
    into_c(match result {
        Ok(value) => json!({ "ok": value }),
        Err(error) => json!({ "error": error }),
    })
}

/// # Safety
/// `text` must be null or a string returned by this library, freed at most once.
#[no_mangle]
pub unsafe extern "C" fn ny_string_free(text: *mut c_char) {
    if !text.is_null() { drop(CString::from_raw(text)); }
}

/// # Safety
/// `handle` must be null or come from `ny_open`, and no call may be in flight.
#[no_mangle]
pub unsafe extern "C" fn ny_close(handle: *mut NyHandle) {
    if !handle.is_null() { drop(Box::from_raw(handle)); }
}

unsafe fn read(text: *const c_char) -> ny_core::Result<String> {
    if text.is_null() { return Err(NyError::invalid_params("Missing string argument.")); }
    CStr::from_ptr(text).to_str().map(str::to_owned).map_err(|_| NyError::invalid_params("Strings must be UTF-8."))
}

fn into_c(value: Value) -> *mut c_char {
    // serde_json escapes NUL as \u0000, so the encoded text never contains an interior NUL.
    CString::new(value.to_string()).map(CString::into_raw).unwrap_or(ptr::null_mut())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn round_trip_through_the_c_abi() {
        unsafe {
            let dir = std::env::temp_dir().join(format!("ny-ffi-{}", std::process::id()));
            let config = CString::new(json!({ "data_dir": dir, "platform": "test" }).to_string()).unwrap();
            let handle = ny_open(config.as_ptr(), None, ptr::null_mut(), ptr::null_mut());
            assert!(!handle.is_null());
            let call = |method: &str, params: Value| {
                let method = CString::new(method).unwrap();
                let params = CString::new(params.to_string()).unwrap();
                let raw = ny_call(handle, method.as_ptr(), params.as_ptr());
                let value: Value = serde_json::from_str(CStr::from_ptr(raw).to_str().unwrap()).unwrap();
                ny_string_free(raw);
                value
            };
            assert_eq!(call("core.info", json!({}))["ok"]["platform"], "test");
            assert_eq!(call("nope.nothing", json!({}))["error"]["code"], "unknown_method");
            ny_close(handle);
            let mut error: *mut c_char = ptr::null_mut();
            let bad = CString::new("{}").unwrap();
            assert!(ny_open(bad.as_ptr(), None, ptr::null_mut(), &mut error).is_null());
            assert!(CStr::from_ptr(error).to_str().unwrap().contains("invalid_params"));
            ny_string_free(error);
            let _ = std::fs::remove_dir_all(dir);
        }
    }
}
