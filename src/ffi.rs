use crate::geometry::{self, Rect};
use crate::identity::{Identity, Namespace};
use crate::search;
use crate::state::{Config, State};

#[no_mangle]
pub extern "C" fn lb_abi_version() -> u32 { 1 }

#[no_mangle]
pub extern "C" fn lb_default_config() -> Config { Config::default() }

#[no_mangle]
pub extern "C" fn lb_initial_state() -> State { State::default() }

#[no_mangle]
pub extern "C" fn lb_step(state: State, config: Config, event: u32, now_ms: u64) -> State {
    state.step(config, event, now_ms)
}

#[no_mangle]
pub extern "C" fn lb_reconfigure(state: State, config: Config, now_ms: u64) -> State {
    state.reconfigure(config, now_ms)
}

#[no_mangle]
pub extern "C" fn lb_next_deadline(state: State) -> u64 { state.next_deadline() }

#[no_mangle]
pub extern "C" fn lb_hidden_length(state: State, config: Config) -> f64 { state.lengths(config).0 }

#[no_mangle]
pub extern "C" fn lb_always_length(state: State, config: Config) -> f64 { state.lengths(config).1 }

#[no_mangle]
pub extern "C" fn lb_section_mask(item: Rect, hidden: Rect, always: Rect, has_always: u32) -> u32 {
    geometry::section_mask(item, hidden, (has_always != 0).then_some(always))
}

unsafe fn read_text<'a>(pointer: *const u8, length: usize, maximum: usize) -> Option<&'a str> {
    if length > maximum || (pointer.is_null() && length != 0) { return None; }
    if length == 0 { return Some(""); }
    let bytes = unsafe { std::slice::from_raw_parts(pointer, length) };
    std::str::from_utf8(bytes).ok()
}

#[allow(clippy::missing_safety_doc)]
#[no_mangle]
pub unsafe extern "C" fn lb_search_score(query: *const u8, query_length: usize, text: *const u8, text_length: usize) -> i32 {
    let Some(query) = (unsafe { read_text(query, query_length, 1024) }) else { return -1; };
    let Some(text) = (unsafe { read_text(text, text_length, 16384) }) else { return -1; };
    search::score(query, text).map_or(-1, |score| score as i32)
}

#[allow(clippy::missing_safety_doc)]
#[no_mangle]
pub unsafe extern "C" fn lb_identity_flags(namespace: *const u8, namespace_length: usize, title: *const u8, title_length: usize) -> u32 {
    let Some(namespace) = (unsafe { read_text(namespace, namespace_length, 1024) }) else { return 0; };
    let Some(title) = (unsafe { read_text(title, title_length, 16384) }) else { return 0; };
    let item = Identity { namespace: Namespace::Named(namespace), title };
    u32::from(item.movable()) | (u32::from(item.hideable()) << 1)
}

#[no_mangle]
pub extern "C" fn lb_event_spec(kind: u32, button: u32) -> crate::events::EventSpec {
    crate::events::event_spec(kind, button)
}

#[no_mangle]
pub extern "C" fn lb_classic_transition(initial: u32, section: u32, action: u32) -> u32 {
    crate::events::classic_transition(initial, section, action)
}
