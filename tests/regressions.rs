use litebar_core::ffi::*;
use litebar_core::geometry::Rect;
use litebar_core::movement::{Candidate, MoveLease};
use litebar_core::state::*;

#[test]
fn deliberate_reveal_stays_pinned_against_hover_rehide() {
    let config = Config {
        flags: HOVER,
        ..Config::default()
    };
    let state = State::default()
        .step(config, POINTER_EMPTY, 1)
        .step(config, SHOW_HIDDEN, 2)
        .step(config, PREVENT_HOVER, 3)
        .step(config, POINTER_OUTSIDE, 4);
    assert_eq!(state.hover_blocked, 2);
    assert_eq!(state.hover_deadline, 0);
    assert!(state.step(config, DEADLINE, 1000).any_visible());
    let state = state
        .step(config, HIDE_ALL, 1001)
        .step(config, POINTER_EMPTY, 1002);
    assert_eq!(state.hover_deadline, 1202);
}

#[test]
fn hover_pin_does_not_disable_timed_rehide() {
    let config = Config {
        flags: HOVER | AUTO_REHIDE,
        rehide_strategy: TIMED,
        rehide_ms: 500,
        ..Config::default()
    };
    let state = State::default()
        .step(config, POINTER_EMPTY, 1)
        .step(config, SHOW_HIDDEN, 2)
        .step(config, PREVENT_HOVER, 3)
        .step(config, POINTER_OUTSIDE, 4);
    assert_eq!(state.hover_deadline, 0);
    assert_eq!(state.rehide_deadline, 504);
    assert!(!state.step(config, DEADLINE, 504).any_visible());
}

#[test]
fn separate_panel_keeps_original_hover_rehide_behavior() {
    let config = Config {
        flags: HOVER | SEPARATE_PANEL,
        ..Config::default()
    };
    let state = State::default()
        .step(config, POINTER_EMPTY, 1)
        .step(config, SHOW_HIDDEN, 2)
        .step(config, PREVENT_HOVER, 3)
        .step(config, POINTER_OUTSIDE, 4);
    assert_eq!(state.hover_blocked, 0);
    assert!(!state.step(config, DEADLINE, 204).any_visible());
}

#[test]
fn command_drag_opens_native_sections_even_with_separate_panel_enabled() {
    let config = Config {
        flags: ALWAYS_ENABLED | SEPARATE_PANEL | HOVER,
        ..Config::default()
    };
    let state = State::default()
        .step(config, SHOW_HIDDEN, 1)
        .step(config, BUTTON_DOWN, 2)
        .step(config, USER_DRAG_BEGIN, 3);
    assert_eq!((state.revealed, state.panel), (3, 0));
    assert_eq!(state.next_deadline(), 0);
    let state = state
        .step(config, BUTTON_UP, 4)
        .step(config, TOGGLE_HIDDEN, 5);
    assert_eq!((state.revealed, state.panel), (0, 0));
    let state = state.step(config, TOGGLE_HIDDEN, 6);
    assert_eq!((state.revealed, state.panel), (0, 1));
}

fn candidate(id: u32, x: f64) -> Candidate {
    Candidate {
        window_id: id,
        process_id: 123,
        display_id: 7,
        flags: 3,
        frame: Rect {
            x,
            y: 0.0,
            width: 20.0,
            height: 24.0,
        },
    }
}

#[test]
fn native_move_ffi_carries_geometry_and_restrictions() {
    let source = candidate(1, 20.0);
    let target = candidate(2, 100.0);
    let planned = lb_plan_move(source, target, 0, 2);
    assert_eq!(planned.status, 0);
    assert_eq!((planned.target_x, planned.target_y), (100.0, 12.0));
    assert_eq!((planned.fallback_x, planned.fallback_y), (30.0, 12.0));
    assert_ne!(
        lb_plan_move(Candidate { flags: 2, ..source }, target, 0, 2).status,
        0
    );
    assert_ne!(
        lb_plan_move(Candidate { flags: 1, ..source }, target, 0, 2).status,
        0
    );
    assert_eq!(
        lb_plan_move(Candidate { flags: 1, ..source }, target, 0, 1).status,
        0
    );
    assert_ne!(
        lb_plan_move(
            source,
            Candidate {
                display_id: 8,
                ..target
            },
            0,
            1
        )
        .status,
        0
    );
    assert_ne!(lb_plan_move(source, target, 0, 0).status, 0);
}

#[test]
fn native_move_wait_never_busy_spins() {
    let mut wait = lb_frame_wait_start(100, 50);
    unsafe {
        assert_eq!(lb_frame_wait_poll(&mut wait, 100), 0);
        assert_eq!(lb_frame_wait_poll(&mut wait, 101), 9);
        assert_eq!(lb_frame_wait_poll(&mut wait, 110), 0);
        assert_eq!(lb_frame_wait_poll(&mut wait, 150), -1);
        assert_eq!(lb_frame_wait_poll(std::ptr::null_mut(), 0), -1);
    }
}

#[test]
fn native_retry_budget_is_identical_to_rust_budget() {
    let mut lease = MoveLease::default();
    unsafe {
        assert_eq!(lb_move_begin(&mut lease, 100), 1);
        assert_eq!(lb_move_begin(&mut lease, 100), 0);
        for n in 1..=5 {
            assert_eq!(lb_move_attempt(&mut lease, 101), n);
        }
        assert_eq!(lb_move_attempt(&mut lease, 102), 0);
        assert_eq!(lb_move_begin(std::ptr::null_mut(), 0), 0);
        assert_eq!(lb_move_attempt(std::ptr::null_mut(), 0), 0);
    }
    assert_eq!(std::mem::size_of::<Candidate>(), 48);
    assert_eq!(std::mem::size_of::<MovePlan>(), 40);
    assert_eq!(std::mem::size_of::<MoveLease>(), 16);
    assert_eq!(std::mem::size_of::<litebar_core::movement::FrameWait>(), 24);
}

#[test]
fn all_native_event_sequences_remain_bounded() {
    let mut seed = 19u64;
    let mut state = State::default();
    let mut config = Config::default();
    for now in 1..100000 {
        seed = seed.wrapping_mul(6364136223846793005).wrapping_add(1);
        if now % 23 == 0 {
            config.flags = (seed >> 32) as u32 & KNOWN_FLAGS;
            config.rehide_strategy = (seed >> 16) as u32 % 3;
            state = state.reconfigure(config, now);
        }
        state = state.step(config, (seed >> 32) as u32 % 23, now);
        assert!(state.revealed <= 3);
        assert_ne!(state.revealed, 2);
        assert!(state.panel <= 2);
        assert!(!(state.panel != 0 && state.revealed != 0));
        if state.suspended != 0 || state.buttons != 0 || state.tracking != 0 {
            assert_eq!(state.next_deadline(), 0);
        }
    }
}

#[test]
fn focused_rehide_waits_for_mouse_up_without_losing_the_focus_change() {
    let config = Config {
        flags: AUTO_REHIDE,
        rehide_strategy: FOCUSED_APP,
        ..Config::default()
    };
    let shown = State::default().step(config, SHOW_HIDDEN, 1);
    let down = shown
        .step(config, BUTTON_DOWN, 2)
        .step(config, FOCUS_CHANGED, 3);
    assert!(down.any_visible());
    assert_eq!(down.pending_rehide, 1);
    assert!(!down.step(config, BUTTON_UP, 4).any_visible());
}

#[test]
fn focused_rehide_waits_for_tracked_menus_to_close() {
    let config = Config {
        flags: AUTO_REHIDE,
        rehide_strategy: FOCUSED_APP,
        ..Config::default()
    };
    let pending = State::default()
        .step(config, SHOW_HIDDEN, 1)
        .step(config, MENU_BEGIN, 2)
        .step(config, FOCUS_CHANGED, 3);
    assert!(pending.any_visible());
    assert!(!pending.step(config, MENU_END, 4).any_visible());
}

#[test]
fn changing_rehide_settings_cancels_a_pending_focus_change() {
    let config = Config {
        flags: AUTO_REHIDE,
        rehide_strategy: FOCUSED_APP,
        ..Config::default()
    };
    let pending = State::default()
        .step(config, SHOW_HIDDEN, 1)
        .step(config, BUTTON_DOWN, 2)
        .step(config, FOCUS_CHANGED, 3);
    let disabled = Config { flags: 0, ..config };
    assert!(pending
        .reconfigure(disabled, 4)
        .step(disabled, BUTTON_UP, 5)
        .any_visible());
}

#[test]
fn hosted_ownership_matches_padded_frames_on_negative_displays() {
    let window = Rect {
        x: -217.0,
        y: 0.0,
        width: 36.0,
        height: 30.0,
    };
    let button = Rect {
        x: -218.0,
        y: 3.0,
        width: 38.0,
        height: 24.0,
    };
    assert_eq!(lb_same_menu_item(window, button), 1);
    assert_eq!(
        lb_same_menu_item(
            window,
            Rect {
                x: 2382.0,
                ..button
            }
        ),
        0
    );
    assert_eq!(
        lb_same_menu_item(
            window,
            Rect {
                width: 0.0,
                ..button
            }
        ),
        0
    );
    assert_eq!(
        lb_same_menu_item(
            window,
            Rect {
                x: f64::NAN,
                ..button
            }
        ),
        0
    );
}

#[test]
fn focused_rehide_does_not_require_moving_the_pointer_off_the_bar() {
    let config = Config {
        flags: AUTO_REHIDE,
        rehide_strategy: FOCUSED_APP,
        ..Config::default()
    };
    let shown = State::default()
        .step(config, SHOW_HIDDEN, 1)
        .step(config, POINTER_BAR, 2);
    assert!(!shown.step(config, FOCUS_CHANGED, 3).any_visible());
}
