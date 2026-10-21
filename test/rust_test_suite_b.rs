mod rust_test_suite_shared;

#[test]
fn shared_source_is_available_to_second_test() {
    assert_eq!(rust_test_suite_shared::answer(), 42);
}
