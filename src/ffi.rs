use crate::geometry::{self, Rect};
use crate::identity::{Identity, Namespace};
use crate::search;
use crate::state::{Config, State};

#[no_mangle]
pub extern "C" fn lb_abi_version() -> u32 {
    1
}

#[no_mangle]
pub extern "C" fn lb_default_config() -> Config {
    Config::default()
}

#[no_mangle]
pub extern "C" fn lb_initial_state() -> State {
    State::default()
}

#[no_mangle]
pub extern "C" fn lb_step(state: State, config: Config, event: u32, now_ms: u64) -> State {
    state.step(config, event, now_ms)
}

#[no_mangle]
pub extern "C" fn lb_reconfigure(state: State, config: Config, now_ms: u64) -> State {
    state.reconfigure(config, now_ms)
}

#[no_mangle]
pub extern "C" fn lb_next_deadline(state: State) -> u64 {
    state.next_deadline()
}

#[no_mangle]
pub extern "C" fn lb_hidden_length(state: State, config: Config) -> f64 {
    state.lengths(config).0
}

#[no_mangle]
pub extern "C" fn lb_always_length(state: State, config: Config) -> f64 {
    state.lengths(config).1
}

#[no_mangle]
pub extern "C" fn lb_section_mask(item: Rect, hidden: Rect, always: Rect, has_always: u32) -> u32 {
    geometry::section_mask(item, hidden, (has_always != 0).then_some(always))
}

unsafe fn read_text<'a>(pointer: *const u8, length: usize, maximum: usize) -> Option<&'a str> {
    if length > maximum || (pointer.is_null() && length != 0) {
        return None;
    }
    if length == 0 {
        return Some("");
    }
    let bytes = unsafe { std::slice::from_raw_parts(pointer, length) };
    std::str::from_utf8(bytes).ok()
}

#[allow(clippy::missing_safety_doc)]
#[no_mangle]
pub unsafe extern "C" fn lb_search_score(
    query: *const u8,
    query_length: usize,
    text: *const u8,
    text_length: usize,
) -> i32 {
    let Some(query) = (unsafe { read_text(query, query_length, 1024) }) else {
        return -1;
    };
    let Some(text) = (unsafe { read_text(text, text_length, 16384) }) else {
        return -1;
    };
    search::score(query, text).map_or(-1, |score| score as i32)
}

#[allow(clippy::missing_safety_doc)]
#[no_mangle]
pub unsafe extern "C" fn lb_identity_flags(
    namespace: *const u8,
    namespace_length: usize,
    title: *const u8,
    title_length: usize,
) -> u32 {
    let Some(namespace) = (unsafe { read_text(namespace, namespace_length, 1024) }) else {
        return 0;
    };
    let Some(title) = (unsafe { read_text(title, title_length, 16384) }) else {
        return 0;
    };
    let item = Identity {
        namespace: Namespace::Named(namespace),
        title,
    };
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

#[repr(C)]
#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct MovePlan {
    pub status: u32,
    pub adjacent: u32,
    pub target_x: f64,
    pub target_y: f64,
    pub fallback_x: f64,
    pub fallback_y: f64,
}

#[no_mangle]
pub extern "C" fn lb_plan_move(
    source: crate::movement::Candidate,
    target: crate::movement::Candidate,
    right: u32,
    section: u32,
) -> MovePlan {
    use crate::geometry::Section;
    use crate::movement::{plan_candidates, Side};
    let section = match section {
        1 => Section::Visible,
        2 => Section::Hidden,
        4 => Section::AlwaysHidden,
        _ => {
            return MovePlan {
                status: 1,
                ..MovePlan::default()
            }
        }
    };
    match plan_candidates(
        source,
        target,
        if right == 0 { Side::Left } else { Side::Right },
        section,
    ) {
        Ok(plan) => MovePlan {
            status: 0,
            adjacent: u32::from(plan.already_adjacent),
            target_x: plan.target_point.0,
            target_y: plan.target_point.1,
            fallback_x: plan.fallback_point.0,
            fallback_y: plan.fallback_point.1,
        },
        Err(_) => MovePlan {
            status: 1,
            ..MovePlan::default()
        },
    }
}

#[no_mangle]
pub extern "C" fn lb_frame_wait_start(now: u64, timeout: u64) -> crate::movement::FrameWait {
    crate::movement::FrameWait::new(now, timeout)
}

#[allow(clippy::missing_safety_doc)]
#[no_mangle]
pub unsafe extern "C" fn lb_frame_wait_poll(
    wait: *mut crate::movement::FrameWait,
    now: u64,
) -> i64 {
    let Some(wait) = (unsafe { wait.as_mut() }) else {
        return -1;
    };
    match wait.poll(now) {
        Ok(crate::movement::Poll::ObserveFrame | crate::movement::Poll::Complete) => 0,
        Ok(crate::movement::Poll::WaitUntil(next)) => next.saturating_sub(now).min(1000) as i64,
        Err(_) => -1,
    }
}

#[allow(clippy::missing_safety_doc)]
#[no_mangle]
pub unsafe extern "C" fn lb_move_begin(lease: *mut crate::movement::MoveLease, now: u64) -> u32 {
    let Some(lease) = (unsafe { lease.as_mut() }) else {
        return 0;
    };
    u32::from(lease.begin(now).is_ok())
}

#[allow(clippy::missing_safety_doc)]
#[no_mangle]
pub unsafe extern "C" fn lb_move_attempt(lease: *mut crate::movement::MoveLease, now: u64) -> u32 {
    let Some(lease) = (unsafe { lease.as_mut() }) else {
        return 0;
    };
    lease.next_attempt(now).unwrap_or(0)
}

#[no_mangle]
pub extern "C" fn lb_interface_showing(on_screen: u32, popup: u32, owner_active: i32) -> u32 {
    let owner = match owner_active {
        -1 => None,
        0 => Some(false),
        _ => Some(true),
    };
    u32::from(crate::recovery::interface_is_showing(
        on_screen != 0,
        popup != 0,
        owner,
    ))
}

#[no_mangle]
pub extern "C" fn lb_restoration_allowed(
    saved_space: u64,
    active_space: u64,
    attempts: u32,
    manual: u32,
) -> u32 {
    u32::from(crate::recovery::restoration_allowed(
        saved_space,
        active_space,
        attempts,
        manual != 0,
    ))
}

#[allow(clippy::missing_safety_doc)]
#[no_mangle]
pub unsafe extern "C" fn lb_resolve_window(
    preferred: u32,
    matches: *const u32,
    count: usize,
) -> u32 {
    if count == 0 || count > 65536 || matches.is_null() {
        return 0;
    }
    crate::recovery::resolve_window(preferred, unsafe {
        std::slice::from_raw_parts(matches, count)
    })
    .unwrap_or(0)
}

#[allow(clippy::missing_safety_doc)]
#[no_mangle]
pub unsafe extern "C" fn lb_store_journal(
    path: *const u8,
    length: usize,
    data: *const u8,
    size: usize,
) -> u32 {
    let Some(path) = (unsafe { read_text(path, length, 4096) }) else {
        return 0;
    };
    if data.is_null() || size == 0 || size > crate::storage::MAX_JOURNAL_BYTES {
        return 0;
    }
    let data = unsafe { std::slice::from_raw_parts(data, size) };
    u32::from(crate::storage::store_journal(std::path::Path::new(path), data).is_ok())
}
