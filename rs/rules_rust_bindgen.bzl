"""Module extension that provisions the rules_rust_bindgen repository."""

def _rules_rust_bindgen_repo_impl(rctx):
    rctx.file("BUILD.bazel", """\
load("@bazel_skylib//:bzl_library.bzl", "bzl_library")

package(default_visibility = ["//visibility:public"])

exports_files([
    "defs.bzl",
])

alias(
    name = "toolchain_type",
    actual = "@rules_rust//extensions/bindgen:toolchain_type",
)

bzl_library(
    name = "bzl_lib",
    srcs = [
        "defs.bzl",
    ],
    deps = [
        "@rules_rust//extensions/bindgen:bzl_lib",
    ],
)
""")

    rctx.file("defs.bzl", """\
load(
    "@rules_rust//extensions/bindgen:defs.bzl",
    _rust_bindgen = "rust_bindgen",
    _rust_bindgen_library = "rust_bindgen_library",
    _rust_bindgen_toolchain = "rust_bindgen_toolchain",
)

rust_bindgen = _rust_bindgen
rust_bindgen_library = _rust_bindgen_library
rust_bindgen_toolchain = _rust_bindgen_toolchain
""")

    return rctx.repo_metadata(reproducible = True)

_rules_rust_bindgen_repo = repository_rule(
    implementation = _rules_rust_bindgen_repo_impl,
)

def _rules_rust_bindgen_impl(mctx):
    _rules_rust_bindgen_repo(
        name = "rules_rust_bindgen",
    )

    return mctx.extension_metadata(
        root_module_direct_deps = ["rules_rust_bindgen"],
        root_module_direct_dev_deps = [],
        reproducible = True,
    )

rules_rust_bindgen = module_extension(
    implementation = _rules_rust_bindgen_impl,
)
