#[repr(C)]
#[derive(Clone, Copy, Debug, Default, Eq, PartialEq)]
pub struct EventSpec {
    pub event_type: u32,
    pub mouse_button: u32,
    pub flags: u64,
    pub click_count: i32,
    pub valid: u32,
}

pub fn event_spec(kind: u32, button: u32) -> EventSpec {
    let Some(event_type) = [1, 2, 3, 4, 25, 26].get(button as usize).copied() else {
        return EventSpec::default();
    };
    if kind > 1 {
        return EventSpec::default();
    }
    EventSpec {
        event_type,
        mouse_button: button / 2,
        flags: if kind == 0 && button == 0 { 1 << 20 } else { 0 },
        click_count: if kind == 1 { 1 } else { -1 },
        valid: 1,
    }
}

pub fn classic_transition(initial: u32, section: u32, action: u32) -> u32 {
    if initial > 3 || section > 2 || action > 2 {
        return initial;
    }
    let bit = if section == 2 { 2 } else { 1 };
    let shown = initial & bit != 0;
    let show = match action {
        0 => true,
        1 => false,
        _ => !shown,
    };
    if show == shown {
        return initial;
    }
    if show {
        initial | if section == 2 { 3 } else { 1 }
    } else if section == 2 {
        initial & !2
    } else {
        0
    }
}
