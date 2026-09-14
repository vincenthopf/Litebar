use litebar_core::geometry::{section_mask, Rect};
use litebar_core::search::score;
use litebar_core::state::{Config, State, TOGGLE_HIDDEN};
use std::hint::black_box;
use std::time::Instant;

fn main() {
    let iterations = 2_000_000u64;
    let mut state = State::default();
    let config = Config::default();
    let start = Instant::now();
    for now in 1..=iterations {
        state = black_box(state).step(black_box(config), black_box(TOGGLE_HIDDEN), now);
    }
    let state_ns = start.elapsed().as_nanos() as f64 / iterations as f64;
    let rect = Rect {
        x: 20.0,
        y: 0.0,
        width: 20.0,
        height: 24.0,
    };
    let hidden = Rect { x: 100.0, ..rect };
    let start = Instant::now();
    for _ in 0..iterations {
        black_box(section_mask(black_box(rect), black_box(hidden), None));
    }
    let geometry_ns = start.elapsed().as_nanos() as f64 / iterations as f64;
    let start = Instant::now();
    for _ in 0..iterations {
        black_box(score(
            black_box("wf"),
            black_box("Wi-Fi com.apple.controlcenter"),
        ));
    }
    let search_ns = start.elapsed().as_nanos() as f64 / iterations as f64;
    println!("{{\"iterations\":{iterations},\"state_ns_per_event\":{state_ns:.3},\"section_ns_per_item\":{geometry_ns:.3},\"search_ns_per_candidate\":{search_ns:.3},\"state_bytes\":{}}}", std::mem::size_of::<State>());
}
