fn main() {
    println!("default {}", rust_crate_example::message());
}

#[cfg(test)]
mod tests {
    #[test]
    fn default_binary_unit_tests_have_dev_dependencies() {
        assert_eq!(dev_dependency::value(), "dev");
        assert_eq!(rust_crate_example::message(), "normal build");
        assert_eq!(env!("CARGO_PKG_NAME"), "rust-crate-example");
        assert_eq!(env!("CARGO_PKG_VERSION"), "0.1.0");
    }
}
