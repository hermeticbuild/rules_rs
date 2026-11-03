load("@rules_rust//rust:extensions.bzl", _rust = "rust", _rust_host_tools = "rust_host_tools")

rust = _rust  # type: ModuleExtension
rust_host_tools = _rust_host_tools  # type: ModuleExtension
