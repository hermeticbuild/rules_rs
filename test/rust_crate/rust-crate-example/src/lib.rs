pub fn message() -> String {
    format!(
        "{} {}",
        normal_dependency::value(),
        env!("RUST_CRATE_BUILD_VALUE")
    )
}

#[cfg(test)]
mod tests {
    #[test]
    fn library_unit_tests_have_normal_dev_and_build_dependencies() {
        assert_eq!(super::message(), "normal build");
        assert_eq!(dev_dependency::value(), "dev");
        assert_eq!(env!("RUST_CRATE_BUILD_VALUE"), "build");
        assert_eq!(env!("CARGO_PKG_NAME"), "rust-crate-example");
        assert_eq!(env!("CARGO_PKG_VERSION"), "0.1.0");
    }
}
