fn main() {
    feature_split_build_macro::check_exec_feature!();
    feature_split_wrapper::exec_only();

    let target_os = std::env::var("CARGO_CFG_TARGET_OS").unwrap();
    let expected = match target_os.as_str() {
        "linux" => "linux",
        "macos" => "macos",
        _ => "other",
    };
    assert_eq!(feature_split_wrapper::build_target_os(), expected);
    assert_eq!(build_only_helper::build_target_os(), expected);
}
