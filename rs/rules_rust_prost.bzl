"""Module extension that provisions the rules_rust_prost repository."""

load("@bazel_tools//tools/build_defs/repo:local.bzl", "local_repository")

def _rules_rust_prost_repo_impl(rctx):
    rctx.file("BUILD.bazel", """\
load("@bazel_skylib//:bzl_library.bzl", "bzl_library")

package(default_visibility = ["//visibility:public"])

exports_files([
    "defs.bzl",
    "providers.bzl",
])

toolchain_type(
    name = "toolchain_type",
)

toolchain(
    name = "default_prost_toolchain",
    toolchain = "@rules_rs//rs/private/prost:default_prost_toolchain_impl",
    toolchain_type = ":toolchain_type",
)

bzl_library(
    name = "bzl_lib",
    srcs = [
        "defs.bzl",
        "providers.bzl",
    ],
    deps = [
        "@rules_rust_prost_upstream//:bzl_lib",
    ],
)
""")

    rctx.file("defs.bzl", """\
load(
    "@rules_rust_prost_upstream//:defs.bzl",
    _rust_prost_library = "rust_prost_library",
    _rust_prost_toolchain = "rust_prost_toolchain",
    _rust_prost_transform = "rust_prost_transform",
)

rust_prost_library = _rust_prost_library
rust_prost_toolchain = _rust_prost_toolchain
rust_prost_transform = _rust_prost_transform
""")

    rctx.file("private/BUILD.bazel", """\
alias(
    name = "protoc_wrapper",
    actual = "@rules_rs//rs/private/prost:protoc_wrapper",
    visibility = ["//visibility:public"],
)

alias(
    name = "protoc_wrapper_source",
    actual = "@rules_rust_prost_upstream//private:protoc_wrapper.rs",
    visibility = ["//visibility:public"],
)
""")

    rctx.file("providers.bzl", """\
load("@rules_rust_prost_upstream//:providers.bzl", _ProstProtoInfo = "ProstProtoInfo")

ProstProtoInfo = _ProstProtoInfo
""")

    return rctx.repo_metadata(reproducible = True)

_rules_rust_prost_repo = repository_rule(
    implementation = _rules_rust_prost_repo_impl,
)

def _rules_rust_prost_impl(mctx):
    prost_module = mctx.path(Label("@rules_rust//:extensions/prost/MODULE.bazel"))
    mctx.read(prost_module)

    local_repository(
        name = "rules_rust_prost_upstream",
        path = str(prost_module.dirname),
    )

    _rules_rust_prost_repo(
        name = "rules_rust_prost",
    )

    return mctx.extension_metadata(
        root_module_direct_deps = ["rules_rust_prost"],
        root_module_direct_dev_deps = [],
        reproducible = True,
    )

rules_rust_prost = module_extension(
    implementation = _rules_rust_prost_impl,
)
