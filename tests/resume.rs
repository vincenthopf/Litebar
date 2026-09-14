use litebar_core::state::{Config, State, DEADLINE, HOVER, POINTER_EMPTY, RESUME};

#[test]
fn duplicate_resume_cancels_pending_hover_without_an_idle_timer() {
    let config = Config { flags: HOVER, ..Config::default() };
    let state = State::default().step(config, POINTER_EMPTY, 100);
    assert_eq!(state.hover_deadline, 300);
    let state = state.step(config, RESUME, 200);
    assert_eq!(state.pointer, 0);
    assert_eq!(state.next_deadline(), 0);
    assert!(!state.step(config, DEADLINE, 300).any_visible());
}
