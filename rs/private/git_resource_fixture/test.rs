#[test]
fn sibling_and_symlinked_resources_are_declared() {
    assert_eq!(member::ROOT, "root");
    assert_eq!(member::SHARED, "schema");
    assert_eq!(member::NESTED, "nested");
    assert_eq!(member::LINK, "schema");
}
