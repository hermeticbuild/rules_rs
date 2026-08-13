pub fn value() -> &'static str {
    assert_eq!(
        std::env::var("CARGO_PKG_NAME").unwrap(),
        "rust-crate-example"
    );
    assert_eq!(std::env::var("CARGO_PKG_VERSION").unwrap(), "0.1.0");
    build_dependency::value()
}
