use std::process::Command;

#[test]
fn binary_only_integration_tests_can_execute_binaries() {
    let default = Command::new(env!("CARGO_BIN_EXE_binary-only"))
        .output()
        .unwrap();
    assert!(default.status.success());
    assert_eq!(
        String::from_utf8(default.stdout).unwrap().trim(),
        "binary-only"
    );

    let other = Command::new(env!("CARGO_BIN_EXE_other-tool"))
        .output()
        .unwrap();
    assert!(other.status.success());
    assert_eq!(
        String::from_utf8(other.stdout).unwrap().trim(),
        "other-tool"
    );
}
