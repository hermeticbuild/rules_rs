"""Module extension that provisions the rules_rust_wasm_bindgen repository."""

load("@bazel_tools//tools/build_defs/repo:local.bzl", "local_repository")

def _rules_rust_wasm_bindgen_repo_impl(rctx):
    rctx.file("BUILD.bazel", """\
load("@bazel_skylib//:bzl_library.bzl", "bzl_library")

package(default_visibility = ["//visibility:public"])

exports_files([
    "defs.bzl",
    "providers.bzl",
])

# Upstream wasm_bindgen.bzl declares its rule with `Label("//:toolchain_type")`,
# which resolves to upstream's repo (not the wrapper's). We alias to that
# canonical target so consumer code that loads `@rules_rust_wasm_bindgen//:toolchain_type`
# resolves to the same target the rule looks up; the default toolchain is
# registered against upstream's type.
alias(
    name = "toolchain_type",
    actual = "@rules_rust_wasm_bindgen_upstream//:toolchain_type",
)

toolchain(
    name = "default_wasm_bindgen_toolchain",
    toolchain = "@rules_rs//rs/private/wasm_bindgen:default_wasm_bindgen_toolchain_impl",
    toolchain_type = "@rules_rust_wasm_bindgen_upstream//:toolchain_type",
)

bzl_library(
    name = "bzl_lib",
    srcs = [
        "defs.bzl",
        "providers.bzl",
    ],
    deps = [
        "@rules_rust_wasm_bindgen_upstream//:bzl_lib",
    ],
)
""")

    rctx.file("defs.bzl", """\
load(
    "@rules_rust_wasm_bindgen_upstream//:defs.bzl",
    _rust_wasm_bindgen = "rust_wasm_bindgen",
    _rust_wasm_bindgen_test = "rust_wasm_bindgen_test",
    _rust_wasm_bindgen_toolchain = "rust_wasm_bindgen_toolchain",
)

rust_wasm_bindgen = _rust_wasm_bindgen
rust_wasm_bindgen_test = _rust_wasm_bindgen_test
rust_wasm_bindgen_toolchain = _rust_wasm_bindgen_toolchain
""")

    rctx.file("private/BUILD.bazel", "")

    rctx.file("private/wasm_bindgen.bzl", """\
load(
    "@rules_rust_wasm_bindgen_upstream//private:wasm_bindgen.bzl",
    _WASM_BINDGEN_ATTR = "WASM_BINDGEN_ATTR",
    _rust_wasm_bindgen_action = "rust_wasm_bindgen_action",
)

WASM_BINDGEN_ATTR = _WASM_BINDGEN_ATTR
rust_wasm_bindgen_action = _rust_wasm_bindgen_action
""")

    rctx.file("providers.bzl", """\
load("@rules_rust_wasm_bindgen_upstream//:providers.bzl", _RustWasmBindgenInfo = "RustWasmBindgenInfo")

RustWasmBindgenInfo = _RustWasmBindgenInfo
""")

    return rctx.repo_metadata(reproducible = True)

_rules_rust_wasm_bindgen_repo = repository_rule(
    implementation = _rules_rust_wasm_bindgen_repo_impl,
)

def _rules_rust_wasm_bindgen_impl(mctx):
    wasm_bindgen_workspace = mctx.path(Label("@rules_rust//:extensions/wasm_bindgen/WORKSPACE.bzlmod"))
    mctx.read(wasm_bindgen_workspace)

    local_repository(
        name = "rules_rust_wasm_bindgen_upstream",
        path = str(wasm_bindgen_workspace.dirname),
    )

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
