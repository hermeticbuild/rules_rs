load("@rules_rust//rust:defs.bzl", _rust_static_library = "rust_static_library")

_DEFAULT_LINT_CONFIG = Label("@rules_rs_default_lint_config//:default")

def rust_static_library(name, **kwargs):
    if "lint_config" not in kwargs:
        kwargs["lint_config"] = _DEFAULT_LINT_CONFIG
    _rust_static_library(name = name, **kwargs)
