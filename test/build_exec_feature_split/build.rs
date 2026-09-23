fn main() {
    selected_shared::exec_only();

    let target_os = std::env::var("CARGO_CFG_TARGET_OS").unwrap();
    let expected = match target_os.as_str() {
        "linux" => "linux",
        "macos" => "macos",
        _ => "other",
    };
    assert_eq!(selected_shared::build_target_os(), expected);
}
