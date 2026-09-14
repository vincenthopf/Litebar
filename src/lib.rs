#![deny(unsafe_op_in_unsafe_fn)]

pub mod events;
pub mod ffi;
pub mod geometry;
pub mod identity;
pub mod movement;
pub mod search;
pub mod state;

#[cfg(target_os = "macos")]
mod macos;
pub mod recovery;
pub mod storage;
