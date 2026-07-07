//! Terminal input encoding.

pub mod function_keys;
pub mod key;
pub mod key_encode;
pub mod key_mods;
pub mod paste;

pub use key::{Action, Key, KeyEvent};
pub use key_encode::{encode, legacy, OptionAsAlt, Options};
pub use key_mods::{Mod, Mods, Side};
