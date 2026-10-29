#![warn(rust_2018_idioms)]

// https://github.com/hermeticbuild/rules_rs/issues/273
#[test]
fn inherited_files_are_readable_across_package_boundaries() {
    assert_eq!(implicit::README, "implicit readme\n");
    assert_eq!(implicit::LICENSE, "implicit license");
    assert_eq!(implicit::AUTHORS, "implicit");
    assert_eq!(implicit::VERSION, "1.2.3");
    assert_eq!(implicit::RUST_VERSION, "1.85");
    assert_eq!(boolean::README, "boolean readme\n");
    assert_eq!(boolean::LICENSE, "boolean license");
    assert_eq!(named::README, "named readme\n");
    assert_eq!(named::LICENSE, "named license");
    assert_eq!(sibling::README, "sibling readme\n");
    assert_eq!(sibling::LICENSE, "sibling license");
    assert_eq!(same::README, "same readme\n");
    assert_eq!(same::LICENSE, "same license");
}

// https://github.com/hermeticbuild/rules_rs/pull/281#discussion_r4407344130
#[test]
fn explicit_false_disables_readme_discovery() {
    assert_eq!(disabled::README_PATH, "");
    assert_eq!(disabled::LICENSE, "disabled license");
}
