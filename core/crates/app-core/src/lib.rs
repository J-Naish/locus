pub const APP_NAME: &str = "Locus";

pub fn core_version() -> &'static str {
    env!("CARGO_PKG_VERSION")
}
