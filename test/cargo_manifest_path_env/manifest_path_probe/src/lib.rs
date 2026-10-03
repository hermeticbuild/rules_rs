pub fn manifest_contents() -> &'static str {
    include_str!(env!("CARGO_MANIFEST_PATH"))
}
