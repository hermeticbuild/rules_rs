load("@bazel_lib//lib:copy_to_directory.bzl", "copy_to_directory")
load("@rules_cc//cc:defs.bzl", "CcInfo", "cc_library")
load("@rules_rs//rs:rules_rust_bindgen.bzl", "rust_bindgen")
load("@rules_rust//rust:rust_common.bzl", "BuildInfo")

def _aws_lc_sys_build_info_impl(ctx):
    out_dir = ctx.file.out_dir
    if not out_dir.is_directory:
        fail("out_dir must be a directory")

    return [
        BuildInfo(
            compile_data = depset(),
            dep_env = None,
            flags = None,
            linker_flags = None,
            link_search_paths = None,
            out_dir = out_dir,
            rustc_env = None,
        ),
        ctx.attr.native[CcInfo],
    ]

_aws_lc_sys_build_info = rule(
    implementation = _aws_lc_sys_build_info_impl,
    attrs = {
        "native": attr.label(mandatory = True, providers = [CcInfo]),
        "out_dir": attr.label(allow_single_file = True, mandatory = True),
    },
)

def aws_lc_sys(name, crypto, ssl):
    """Injects generated bindings and native AWS-LC dependencies into aws-lc-sys."""
    wrapper = name + "_wrapper"
    out_dir = name + "_out_dir"

    cc_library(
        name = wrapper,
        hdrs = ["include/rust_wrapper.h"],
        deps = [crypto, ssl],
    )

    rust_bindgen(
        name = "bindings",
        bindgen_flags = [
            "--allowlist-file=.*(/|\\\\)openssl((/|\\\\)[^/\\\\]+)+\\.h",
            "--allowlist-file=.*(/|\\\\)rust_wrapper\\.h",
            "--rustified-enum=point_conversion_form_t",
            "--default-macro-constant-type=signed",
            "--with-derive-default",
            "--with-derive-partialeq",
            "--with-derive-eq",
            "--generate=functions,types,vars,methods,constructors,destructors",
            "--rust-edition=2021",
            "--rust-target=1.70",
        ] + select({
            "@platforms//os:macos": ["--prefix-link-name=_aws_lc_bazel_"],
            "//conditions:default": ["--prefix-link-name=aws_lc_bazel_"],
        }),
        cc_lib = wrapper,
        clang_flags = [
            "-DAWS_LC_RUST_INCLUDE_SSL",
            "-DBORINGSSL_PREFIX_SYMBOLS_H",
        ],
        header = "include/rust_wrapper.h",
    )

    copy_to_directory(
        name = out_dir,
        srcs = ["bindings"],
    )

    _aws_lc_sys_build_info(
        name = name,
        native = wrapper,
        out_dir = out_dir,
        visibility = ["//visibility:public"],
    )
