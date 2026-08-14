"""Public Rust toolchain macro."""

load("//rs/toolchains:declare_rustc_toolchains.bzl", _rust_toolchain = "rust_toolchain")

rust_toolchain = _rust_toolchain
