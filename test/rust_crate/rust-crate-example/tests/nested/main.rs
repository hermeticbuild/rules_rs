#[path = "../common/mod.rs"]
mod common;

#[test]
fn nested_integration_tests_share_support_modules() {
    common::assert_dependencies();
}
