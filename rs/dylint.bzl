"""Public Dylint rules for rules_rs."""

load(
    "//rs/private:dylint.bzl",
    _dylint_config = "dylint_config",
    _dylint_library = "dylint_library",
    _dylint_toolchain = "dylint_toolchain",
    _rust_dylint = "rust_dylint",
)

dylint_config = _dylint_config
dylint_library = _dylint_library
dylint_toolchain = _dylint_toolchain
rust_dylint = _rust_dylint
