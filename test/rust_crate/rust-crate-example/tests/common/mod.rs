pub fn assert_dependencies() {
    assert_eq!(rust_crate_example::message(), "normal build");
    assert_eq!(normal_dependency::value(), "normal");
    assert_eq!(dev_dependency::value(), "dev");
    assert_eq!(env!("RUST_CRATE_BUILD_VALUE"), "build");
    assert_eq!(env!("CARGO_PKG_NAME"), "rust-crate-example");
    assert_eq!(env!("CARGO_PKG_VERSION"), "0.1.0");
}
