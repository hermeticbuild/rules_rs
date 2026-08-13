mod common;

#[test]
fn integration_tests_have_normal_dev_and_build_dependencies() {
    common::assert_dependencies();
}
