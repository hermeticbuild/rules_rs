"""Module extension that provisions the rules_rust_wasm_bindgen repository."""

def _rules_rust_wasm_bindgen_repo_impl(rctx):
    rctx.file("BUILD.bazel", """\
load("@bazel_skylib//:bzl_library.bzl", "bzl_library")

package(default_visibility = ["//visibility:public"])

exports_files([
    "defs.bzl",
    "providers.bzl",
])

alias(
    name = "toolchain_type",
    actual = "@rules_rust//extensions/wasm_bindgen:toolchain_type",
)

toolchain(
    name = "default_wasm_bindgen_toolchain",
    toolchain = "@rules_rs//rs/private/wasm_bindgen:default_wasm_bindgen_toolchain_impl",
    toolchain_type = "@rules_rust//extensions/wasm_bindgen:toolchain_type",
)

bzl_library(
    name = "bzl_lib",
    srcs = [
        "defs.bzl",
        "providers.bzl",
    ],
    deps = [
        "@rules_rust//extensions/wasm_bindgen:bzl_lib",
    ],
)
""")

    rctx.file("defs.bzl", """\
load(
    "@rules_rust//extensions/wasm_bindgen:defs.bzl",
    _RustWasmBindgenInfo = "RustWasmBindgenInfo",
    _rust_wasm_bindgen = "rust_wasm_bindgen",
    _rust_wasm_bindgen_test = "rust_wasm_bindgen_test",
    _rust_wasm_bindgen_toolchain = "rust_wasm_bindgen_toolchain",
)

rust_wasm_bindgen = _rust_wasm_bindgen
rust_wasm_bindgen_test = _rust_wasm_bindgen_test
rust_wasm_bindgen_toolchain = _rust_wasm_bindgen_toolchain
RustWasmBindgenInfo = _RustWasmBindgenInfo
""")

    rctx.file("providers.bzl", """\
load("@rules_rust//extensions/wasm_bindgen:providers.bzl", _RustWasmBindgenInfo = "RustWasmBindgenInfo")

RustWasmBindgenInfo = _RustWasmBindgenInfo
""")

    return rctx.repo_metadata(reproducible = True)

_rules_rust_wasm_bindgen_repo = repository_rule(
    implementation = _rules_rust_wasm_bindgen_repo_impl,
)

def _rules_rust_wasm_bindgen_impl(mctx):
    _rules_rust_wasm_bindgen_repo(
        name = "rules_rust_wasm_bindgen",
    )

    return mctx.extension_metadata(
        root_module_direct_deps = ["rules_rust_wasm_bindgen"],
        root_module_direct_dev_deps = [],
        reproducible = True,
    )

rules_rust_wasm_bindgen = module_extension(
    implementation = _rules_rust_wasm_bindgen_impl,
)
