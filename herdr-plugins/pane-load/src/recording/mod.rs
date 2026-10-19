//! Canonical recording model shared by native input, replay, and binary profiles.
pub mod cli;
mod model;
mod ownership;
pub mod pipeline;
pub mod source;
pub mod store;
pub mod wire;

pub use model::*;
pub use wire::{decode_block, encode_block};
