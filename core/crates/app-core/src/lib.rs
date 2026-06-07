pub mod file_type;
pub mod line_index;
pub mod text_buffer;
pub mod workspace;

pub const APP_NAME: &str = "Locus";

pub fn core_version() -> &'static str {
    env!("CARGO_PKG_VERSION")
}
