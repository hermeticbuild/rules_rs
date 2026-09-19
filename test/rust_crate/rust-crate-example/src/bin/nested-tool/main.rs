fn main() {
    println!("nested {}", rust_crate_example::message());
}

#[cfg(test)]
mod tests {
    #[test]
    fn nested_binary_unit_tests_have_dev_dependencies() {
        assert_eq!(dev_dependency::value(), "dev");
        assert_eq!(rust_crate_example::message(), "normal build");
    }
}
