#[path = "../../tests/common/mod.rs"]
mod contract;

fn main() {
    print!("{}", contract::output());
}
