#[test]
fn resolves_and_links_external_vendored_dependency() {
    assert_eq!(vendored_dependency::add(2, 3), 5);
}
