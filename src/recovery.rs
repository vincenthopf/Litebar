pub const MAX_TEMPORARY_ITEMS: usize = 16;
pub const MAX_AUTOMATIC_ATTEMPTS: u32 = 3;

pub fn interface_is_showing(on_screen: bool, popup: bool, owner_active: Option<bool>) -> bool {
    on_screen && (popup || owner_active.unwrap_or(true))
}

pub fn resolve_window(preferred: u32, matches: &[u32]) -> Option<u32> {
    if preferred != 0 && matches.contains(&preferred) {
        return Some(preferred);
    }
    match matches {
        [single] if *single != 0 => Some(*single),
        _ => None,
    }
}

pub fn restoration_allowed(
    saved_space: u64,
    active_space: u64,
    attempts: u32,
    manual: bool,
) -> bool {
    active_space != 0
        && active_space == saved_space
        && (manual || attempts < MAX_AUTOMATIC_ATTEMPTS)
}
