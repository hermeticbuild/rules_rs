#[test]
fn omitted_version_defaults_to_0_0_0() {
    assert_eq!(unversioned::VERSION, "0.0.0");
}
