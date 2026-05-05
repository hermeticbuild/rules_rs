"""Module extension that provisions the rules_rust_pyo3 repository."""

def _rules_rust_pyo3_repo_impl(rctx):
    rctx.file("BUILD.bazel", """\
load("@bazel_skylib//:bzl_library.bzl", "bzl_library")
load("@rules_rust//extensions/pyo3/private:pyo3_toolchain.bzl", "current_pyo3_toolchain")

package(default_visibility = ["//visibility:public"])

exports_files([
    "defs.bzl",
])

alias(
    name = "toolchain_type",
    actual = "@rules_rust//extensions/pyo3:toolchain_type",
)

alias(
    name = "rust_toolchain_type",
    actual = "@rules_rust//extensions/pyo3:rust_toolchain_type",
)

current_pyo3_toolchain(
    name = "current_pyo3_toolchain",
)

bzl_library(
    name = "bzl_lib",
    srcs = ["defs.bzl"],
    deps = [
        "@rules_rust//extensions/pyo3:bzl_lib",
    ],
)
""")

    rctx.file("defs.bzl", """\
load(
    "@rules_rust//extensions/pyo3:defs.bzl",
    _pyo3_extension = "pyo3_extension",
    _pyo3_toolchain = "pyo3_toolchain",
    _rust_pyo3_toolchain = "rust_pyo3_toolchain",
)

pyo3_extension = _pyo3_extension
pyo3_toolchain = _pyo3_toolchain
rust_pyo3_toolchain = _rust_pyo3_toolchain
""")

    rctx.file("private/BUILD.bazel", """\
package(default_visibility = ["//visibility:public"])

alias(
    name = "current_pyo3_toolchain",
    actual = "//:current_pyo3_toolchain",
)

alias(
    name = "current_rust_pyo3_toolchain",
    actual = "@rules_rs//rs/private/pyo3:current_rust_pyo3_toolchain",
)

alias(
    name = "current_rust_pyo3_introspection_toolchain",
    actual = "@rules_rs//rs/private/pyo3:current_rust_pyo3_introspection_toolchain",
)

alias(
    name = "stubgen",
    actual = "@rules_rs//rs/private/pyo3:stubgen",
)
""")

    rctx.file("settings/BUILD.bazel", """\
load("@bazel_skylib//rules:common_settings.bzl", "bool_flag")

package(default_visibility = ["//visibility:public"])

bool_flag(
    name = "experimental_stubgen",
    build_setting_default = True,
)
""")

    rctx.file("toolchains/BUILD.bazel", """\
load("@rules_rust//extensions/pyo3:defs.bzl", "pyo3_toolchain")

package(default_visibility = ["//visibility:public"])

pyo3_toolchain(
    name = "pyo3_toolchain",
)

toolchain(
    name = "toolchain",
    toolchain = ":pyo3_toolchain",
    toolchain_type = "@rules_rust//extensions/pyo3:toolchain_type",
)

toolchain(
    name = "rust_toolchain",
    toolchain = "@rules_rs//rs/private/pyo3:rust_pyo3_toolchain",
    toolchain_type = "@rules_rust//extensions/pyo3:rust_toolchain_type",
)
""")

    return rctx.repo_metadata(reproducible = True)

_rules_rust_pyo3_repo = repository_rule(
    implementation = _rules_rust_pyo3_repo_impl,
)

def _rules_rust_pyo3_impl(mctx):
    _rules_rust_pyo3_repo(
        name = "rules_rust_pyo3",
    )

    return mctx.extension_metadata(
        root_module_direct_deps = ["rules_rust_pyo3"],
        root_module_direct_dev_deps = [],
        reproducible = True,
    )

rules_rust_pyo3 = module_extension(
    implementation = _rules_rust_pyo3_impl,
)
