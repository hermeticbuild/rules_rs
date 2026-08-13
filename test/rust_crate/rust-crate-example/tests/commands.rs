use std::process::Command;

mod common;

fn assert_command(binary: &str, expected: &str) {
    let output = Command::new(binary).output().unwrap();
    assert!(output.status.success());
    assert_eq!(String::from_utf8(output.stdout).unwrap().trim(), expected);
}

#[test]
fn integration_tests_can_execute_cargo_binaries() {
    common::assert_dependencies();
    assert_eq!(
        std::env::var("CARGO_BIN_EXE_extra-tool").unwrap(),
        env!("CARGO_BIN_EXE_extra-tool")
    );
    assert_command(
        env!("CARGO_BIN_EXE_rust-crate-example"),
        "default normal build",
    );
    assert_command(env!("CARGO_BIN_EXE_extra-tool"), "extra normal build");
    assert_command(env!("CARGO_BIN_EXE_nested-tool"), "nested normal build");
}
