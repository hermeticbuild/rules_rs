load("@rules_rust//rust:defs.bzl", _rust_proc_macro = "rust_proc_macro")

_DEFAULT_LINT_CONFIG = Label("@rules_rs_default_lint_config//:default")

def rust_proc_macro(name, **kwargs):
    if "lint_config" not in kwargs:
        kwargs["lint_config"] = _DEFAULT_LINT_CONFIG
    _rust_proc_macro(name = name, **kwargs)
