pub const CARGO_MANIFEST_PATH: &str = env!("CARGO_MANIFEST_PATH");

pub fn manifest_path() -> &'static str {
    CARGO_MANIFEST_PATH
}
