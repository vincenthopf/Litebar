mod common;
use litebar_core::events::{classic_transition, event_spec};
use litebar_core::ffi;
use litebar_core::geometry::{appkit_to_quartz, classify, section_mask, Rect, Section};
use litebar_core::identity::{Identity, Namespace};
use litebar_core::movement::{plan, FrameWait, Item, MoveError, MoveLease, Poll, Side};
use litebar_core::search::score;
use litebar_core::state::*;

fn rect(x: f64, width: f64) -> Rect { Rect { x, y: 0.0, width, height: 24.0 } }
fn timed() -> Config { Config { rehide_strategy: TIMED, rehide_ms: 500, ..Config::default() } }

#[test]
fn original_contracts() { assert_eq!(common::output().lines().count(), 80); }

#[test]
fn original_defaults() {
    let config = Config::default();
    assert_eq!(config.flags, CLICK | SCROLL | AUTO_REHIDE);
    assert_eq!(config.rehide_strategy, SMART);
    assert_eq!(config.rehide_ms, 15000);
    assert_eq!(config.hover_ms, 200);
}

#[test]
fn literal_null_is_not_absent() {
    assert_eq!(Namespace::Absent.as_option(), None);
    assert_eq!(Namespace::Named("<null>").as_option(), Some("<null>"));
    assert_ne!(Namespace::Absent, Namespace::Named("<null>"));
}

#[test]
fn zero_width_boundary_preserves_predicate_overlap_and_priority() {
    assert_eq!(section_mask(rect(100.0, 0.0), rect(100.0, 0.0), Some(rect(50.0, 0.0))), 3);
    assert_eq!(classify(rect(100.0, 0.0), rect(100.0, 0.0), None), Some(Section::Visible));
}

#[test]
fn invalid_geometry_cannot_classify() {
    for value in [f64::NAN, f64::INFINITY, f64::NEG_INFINITY] {
        assert_eq!(section_mask(rect(value, 10.0), rect(0.0, 10.0), None), 0);
        assert!(!rect(value, 10.0).contains(0.0, 0.0));
    }
    assert!(!rect(f64::MAX, f64::MAX).valid());
}

#[test]
fn negative_extents_are_standardized_like_cgrect() {
    assert_eq!(section_mask(rect(140.0, -20.0), rect(100.0, 10.0), None), 1);
    assert_eq!(rect(140.0, -20.0).min_x(), 120.0);
}

#[test]
fn screen_conversion_uses_primary_origin_not_per_display_height() {
    let input = Rect { x: -1920.0, y: -200.0, width: 100.0, height: 24.0 };
    let result = appkit_to_quartz(input, 1080.0).unwrap();
    assert_eq!(result.x, -1920.0);
    assert_eq!(result.y, 1256.0);
}

#[test]
fn idle_has_no_deadline() {
    let state = State::default().step(Config::default(), DEADLINE, 1000);
    assert_eq!(state.next_deadline(), 0);
    assert!(!state.any_visible());
}

#[test]
fn timed_rehide_fires_once() {
    let config = timed();
    let state = State::default().step(config, TOGGLE_HIDDEN, 100);
    assert_eq!(state.rehide_deadline, 600);
    assert!(state.step(config, DEADLINE, 599).any_visible());
    let state = state.step(config, DEADLINE, 600);
    assert!(!state.any_visible());
    assert_eq!(state.next_deadline(), 0);
}

#[test]
fn repeated_pointer_events_do_not_postpone_rehide() {
    let config = timed();
    let state = State::default().step(config, TOGGLE_HIDDEN, 100);
    assert_eq!(state.step(config, POINTER_OUTSIDE, 200).rehide_deadline, 600);
}

#[test]
fn reentering_bar_cancels_rehide() {
    let config = timed();
    let state = State::default().step(config, TOGGLE_HIDDEN, 100).step(config, POINTER_BAR, 200);
    assert_eq!(state.rehide_deadline, 0);
    assert!(state.step(config, DEADLINE, 1000).any_visible());
    assert_eq!(state.step(config, POINTER_OUTSIDE, 1200).rehide_deadline, 1700);
}

#[test]
fn hover_debounces_without_allocating_tasks_per_mouse_event() {
    let config = Config { flags: HOVER, ..Config::default() };
    let state = State::default().step(config, POINTER_EMPTY, 100);
    assert_eq!(state.hover_deadline, 300);
    let state = state.step(config, POINTER_EMPTY, 250);
    assert_eq!(state.hover_deadline, 300);
    assert!(!state.step(config, DEADLINE, 299).any_visible());
    assert!(state.step(config, DEADLINE, 300).any_visible());
}

#[test]
fn hover_only_shows_in_empty_menu_bar_space() {
    let config = Config { flags: HOVER, ..Config::default() };
    let state = State::default().step(config, POINTER_EMPTY, 100).step(config, POINTER_BAR, 200);
    assert_eq!(state.next_deadline(), 0);
    assert!(!state.step(config, DEADLINE, 1000).any_visible());
}

#[test]
fn explicit_hide_blocks_hover_until_pointer_leaves() {
    let config = Config { flags: HOVER, ..Config::default() };
    let state = State::default().step(config, POINTER_EMPTY, 100).step(config, TOGGLE_HIDDEN, 101).step(config, HIDE_ALL, 102);
    assert_eq!(state.hover_blocked, 1);
    assert_eq!(state.step(config, POINTER_EMPTY, 103).next_deadline(), 0);
    let state = state.step(config, POINTER_OUTSIDE, 104).step(config, POINTER_EMPTY, 105);
    assert_eq!(state.hover_deadline, 305);
}

#[test]
fn hover_rehides_without_auto_rehide_enabled() {
    let config = Config { flags: HOVER, ..Config::default() };
    let state = State::default().step(config, POINTER_EMPTY, 100).step(config, TOGGLE_HIDDEN, 101).step(config, POINTER_OUTSIDE, 200);
    assert_eq!(state.hover_deadline, 400);
    assert!(!state.step(config, DEADLINE, 400).any_visible());
}

#[test]
fn always_section_requires_enable_and_reveals_hidden_too() {
    let off = Config::default();
    assert_eq!(State::default().step(off, TOGGLE_ALWAYS, 1).revealed, 0);
    let on = Config { flags: off.flags | ALWAYS_ENABLED, ..off };
    let state = State::default().step(on, TOGGLE_ALWAYS, 1);
    assert_eq!(state.revealed, 3);
    assert_eq!(state.step(on, TOGGLE_ALWAYS, 2).revealed, 1);
    assert_eq!(state.step(on, TOGGLE_HIDDEN, 2).revealed, 0);
}

#[test]
fn panel_reveals_without_expanding_native_sections() {
    let config = Config { flags: SEPARATE_PANEL | ALWAYS_ENABLED, ..Config::default() };
    let state = State::default().step(config, TOGGLE_HIDDEN, 1);
    assert_eq!((state.revealed, state.panel), (0, 1));
    assert_eq!(state.lengths(config), (10000.0, 10000.0));
    let state = state.step(config, TOGGLE_ALWAYS, 2);
    assert_eq!((state.revealed, state.panel), (0, 2));
}

#[test]
fn nested_menu_tracking_is_balanced_and_blocks_rehide() {
    let config = timed();
    let state = State::default().step(config, SHOW_HIDDEN, 1).step(config, MENU_BEGIN, 2).step(config, MENU_BEGIN, 3);
    assert_eq!(state.tracking, 2);
    assert_eq!(state.next_deadline(), 0);
    let state = state.step(config, MENU_END, 10);
    assert_eq!(state.tracking, 1);
    assert_eq!(state.next_deadline(), 0);
    let state = state.step(config, MENU_END, 20);
    assert_eq!(state.rehide_deadline, 520);
    assert_eq!(state.step(config, MENU_END, 21).tracking, 0);
}

#[test]
fn dragging_blocks_deadlines() {
    let config = timed();
    let state = State::default().step(config, SHOW_HIDDEN, 1).step(config, BUTTON_DOWN, 2);
    assert_eq!(state.next_deadline(), 0);
    assert!(state.step(config, DEADLINE, 1000).any_visible());
    assert_eq!(state.step(config, BUTTON_UP, 20).rehide_deadline, 520);
}

#[test]
fn sleep_clears_timers_and_resumes_without_stuck_buttons() {
    let config = timed();
    let state = State::default().step(config, SHOW_HIDDEN, 1).step(config, BUTTON_DOWN, 2).step(config, SUSPEND, 3);
    assert_eq!(state.next_deadline(), 0);
    assert!(!state.step(config, SHOW_HIDDEN, 4).any_visible());
    let state = state.step(config, RESUME, 100);
    assert_eq!((state.buttons, state.tracking, state.suspended), (0, 0, 0));
    assert!(state.step(config, SHOW_HIDDEN, 101).any_visible());
}

#[test]
fn focused_and_smart_strategies_are_distinct() {
    let config = Config { rehide_strategy: FOCUSED_APP, ..Config::default() };
    let state = State::default().step(config, SHOW_HIDDEN, 1);
    assert_eq!(state.next_deadline(), 0);
    assert!(state.step(config, SMART_REHIDE, 2).any_visible());
    assert!(!state.step(config, FOCUS_CHANGED, 2).any_visible());
    let config = Config::default();
    assert!(state.step(config, FOCUS_CHANGED, 2).any_visible());
    assert!(!state.step(config, SMART_REHIDE, 2).any_visible());
}

#[test]
fn configuration_change_cancels_unsupported_state() {
    let config = Config { flags: ALWAYS_ENABLED | SEPARATE_PANEL, ..Config::default() };
    let state = State::default().step(config, TOGGLE_ALWAYS, 1).reconfigure(Config::default(), 2);
    assert!(!state.any_visible());
    assert_eq!(state.next_deadline(), 0);
}

#[test]
fn pathological_timing_does_not_overflow() {
    let config = Config { rehide_ms: u64::MAX, rehide_strategy: TIMED, ..Config::default() };
    assert_eq!(config.normalized().rehide_ms, 3600000);
    let state = State::default().step(config, SHOW_HIDDEN, u64::MAX - 1);
    assert_eq!(state.rehide_deadline, u64::MAX);
    assert!(!state.step(config, DEADLINE, u64::MAX).any_visible());
}

#[test]
fn clock_never_moves_backwards() {
    let state = State::default().step(Config::default(), 999, 100).step(Config::default(), 999, 1);
    assert_eq!(state.last_time, 100);
}

#[test]
fn search_is_unicode_aware_and_bounded() {
    assert_eq!(score("", "Wi-Fi"), Some(0));
    assert_eq!(score(" WIFI ", "wifi"), Some(0));
    assert_eq!(score("应用", "应用"), Some(0));
    assert!(score("wf", "Wi-Fi").is_some());
    assert!(score("zz", "Wi-Fi").is_none());
    assert!(score(&"q".repeat(1025), "q").is_none());
    assert!(score("q", &"q".repeat(16385)).is_none());
}

#[test]
fn invalid_ffi_strings_fail_closed() {
    unsafe {
        assert_eq!(ffi::lb_search_score(std::ptr::null(), 1, std::ptr::null(), 0), -1);
        assert_eq!(ffi::lb_search_score(std::ptr::null(), 0, std::ptr::null(), 0), 0);
        let invalid = [255u8];
        assert_eq!(ffi::lb_search_score(invalid.as_ptr(), 1, std::ptr::null(), 0), -1);
        assert_eq!(ffi::lb_identity_flags(std::ptr::null(), usize::MAX, std::ptr::null(), 0), 0);
    }
}

fn item(id: u32, identity: &str, x: f64) -> Item<'_> {
    Item { window_id: id, process_id: 123, display_id: 1, identity: Identity::parse(identity), frame: rect(x, 20.0) }
}

#[test]
fn movement_rejects_protected_items_and_preserves_recording_indicator() {
    let target = item(2, "example:target", 100.0);
    assert_eq!(plan(item(1, "com.apple.controlcenter:Clock", 20.0), target, Side::Left, Section::Hidden), Err(MoveError::ProtectedItem));
    assert_eq!(plan(item(1, "com.apple.controlcenter:AudioVideoModule", 20.0), target, Side::Left, Section::Hidden), Err(MoveError::CannotHide));
}

#[test]
fn movement_carries_original_fallback_and_both_process_ids() {
    let target = Item { process_id: 456, ..item(2, "example:target", 100.0) };
    let result = plan(item(1, "example:item", 20.0), target, Side::Left, Section::Visible).unwrap();
    assert_eq!(result.target_point, (100.0, 12.0));
    assert_eq!(result.fallback_point, (30.0, 12.0));
    assert_eq!((result.source_pid, result.target_pid), (123, 456));
    assert!(!result.already_adjacent);
}

#[test]
fn movement_rejects_cross_display_and_self() {
    let source = item(1, "example:item", 20.0);
    assert_eq!(plan(source, source, Side::Left, Section::Visible), Err(MoveError::SameItem));
    let target = Item { display_id: 2, ..item(2, "example:target", 100.0) };
    assert_eq!(plan(source, target, Side::Left, Section::Visible), Err(MoveError::DifferentDisplay));
}

#[test]
fn frame_wait_is_bounded_and_does_not_busy_spin() {
    let mut wait = FrameWait::new(100, 50);
    assert_eq!(wait.poll(100), Ok(Poll::ObserveFrame));
    for now in 101..110 { assert_eq!(wait.poll(now), Ok(Poll::WaitUntil(110))); }
    assert_eq!(wait.poll(110), Ok(Poll::ObserveFrame));
    assert_eq!(wait.poll(150), Err(MoveError::TimedOut));
    wait.observe(true);
    assert_eq!(wait.poll(151), Ok(Poll::Complete));
}

#[test]
fn movement_retry_budget_and_exclusion() {
    let mut lease = MoveLease::default();
    assert_eq!(lease.begin(1), Ok(()));
    assert_eq!(lease.begin(2), Err(MoveError::Busy));
    for attempt in 1..=5 { assert_eq!(lease.next_attempt(3), Ok(attempt)); }
    assert_eq!(lease.next_attempt(4), Err(MoveError::Failed));
    lease.finish();
    assert_eq!(lease.begin(5), Ok(()));
    assert_eq!(lease.next_attempt(2005), Err(MoveError::TimedOut));
}

#[test]
fn event_spec_leaves_move_click_count_at_native_default() {
    assert_eq!(event_spec(0, 0).click_count, -1);
    assert_eq!(event_spec(1, 0).click_count, 1);
    assert_eq!(event_spec(0, 0).flags, 1 << 20);
    assert_eq!(event_spec(0, 1).flags, 0);
    assert_eq!(event_spec(0, 6).valid, 0);
}

#[test]
fn abi_sizes_and_version() {
    assert_eq!(ffi::lb_abi_version(), 1);
    assert_eq!(std::mem::size_of::<State>(), 56);
    assert_eq!(std::mem::size_of::<Config>(), 24);
    assert_eq!(std::mem::size_of::<Rect>(), 32);
    assert_eq!(std::mem::size_of::<litebar_core::events::EventSpec>(), 24);
}

#[test]
fn unknown_classic_commands_do_not_mutate_state() {
    assert_eq!(classic_transition(3, 99, 0), 3);
    assert_eq!(classic_transition(3, 0, 99), 3);
}

#[test]
fn generated_event_sequences_preserve_visibility_and_idle_invariants() {
    let mut seed = 0x12345678u64;
    let mut state = State::default();
    let mut config = Config::default();
    for now in 1..25000 {
        seed = seed.wrapping_mul(6364136223846793005).wrapping_add(1);
        if now % 37 == 0 {
            config.flags = (seed >> 32) as u32 & KNOWN_FLAGS;
            config.rehide_strategy = (seed >> 16) as u32 % 3;
            state = state.reconfigure(config, now);
        }
        state = state.step(config, (seed >> 32) as u32 % 21, now);
        assert!(state.revealed <= 3);
        assert_ne!(state.revealed, 2);
        assert!(state.panel <= 2);
        assert!(!(state.panel != 0 && state.revealed != 0));
        if state.suspended != 0 || state.buttons != 0 || state.tracking != 0 { assert_eq!(state.next_deadline(), 0); }
        if !state.any_visible() && state.pointer == 0 { assert_eq!(state.next_deadline(), 0); }
    }
}
