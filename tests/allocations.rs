use litebar_core::geometry::{section_mask, Rect};
use litebar_core::identity::Identity;
use litebar_core::search::score;
use litebar_core::state::*;
use std::alloc::{GlobalAlloc, Layout, System};
use std::cell::Cell;
use std::hint::black_box;

struct Counting;
thread_local! {
    static TRACK: Cell<bool> = const { Cell::new(false) };
    static ALLOCATIONS: Cell<usize> = const { Cell::new(0) };
}

unsafe impl GlobalAlloc for Counting {
    unsafe fn alloc(&self, layout: Layout) -> *mut u8 {
        if TRACK.try_with(Cell::get).unwrap_or(false) {
            let _ = ALLOCATIONS.try_with(|count| count.set(count.get() + 1));
        }
        unsafe { System.alloc(layout) }
    }
    unsafe fn dealloc(&self, pointer: *mut u8, layout: Layout) {
        unsafe { System.dealloc(pointer, layout) }
    }
    unsafe fn realloc(&self, pointer: *mut u8, layout: Layout, size: usize) -> *mut u8 {
        if TRACK.try_with(Cell::get).unwrap_or(false) {
            let _ = ALLOCATIONS.try_with(|count| count.set(count.get() + 1));
        }
        unsafe { System.realloc(pointer, layout, size) }
    }
}

#[global_allocator]
static ALLOCATOR: Counting = Counting;

#[test]
fn policy_and_search_hot_paths_allocate_nothing() {
    let config = Config::default();
    let rect = Rect {
        x: 0.0,
        y: 0.0,
        width: 20.0,
        height: 24.0,
    };
    let hidden = Rect { x: 100.0, ..rect };
    let mut state = State::default();
    ALLOCATIONS.set(0);
    TRACK.set(true);
    for now in 1..100000 {
        state = black_box(state).step(black_box(config), black_box(TOGGLE_HIDDEN), now);
        black_box(section_mask(black_box(rect), black_box(hidden), None));
        black_box(
            Identity::parse(black_box("com.apple.controlcenter:AudioVideoModule")).hideable(),
        );
        black_box(score(black_box("wf"), black_box("Wi-Fi")));
        black_box(score(black_box("应用"), black_box("应用菜单")));
    }
    TRACK.set(false);
    assert_eq!(ALLOCATIONS.get(), 0);
}
