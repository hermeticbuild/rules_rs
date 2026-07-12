"""coreaudio-sys build-script replacement."""

load("@bazel_lib//lib:copy_to_directory.bzl", "copy_to_directory")
load("@rules_cc//cc:defs.bzl", "CcInfo", "cc_library")
load("@rules_rs//rs:rules_rust_bindgen.bzl", "rust_bindgen")
load("@rules_rust//rust:rust_common.bzl", "BuildInfo")

def _coreaudio_sys_build_info_impl(ctx):
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
        ctx.attr.cc_lib[CcInfo],
    ]

_coreaudio_sys_build_info = rule(
    implementation = _coreaudio_sys_build_info_impl,
    attrs = {
        "cc_lib": attr.label(mandatory = True, providers = [CcInfo]),
        "out_dir": attr.label(allow_single_file = True, mandatory = True),
    },
)

def coreaudio_sys(name):
    """Injects generated CoreAudio bindings and framework dependencies."""
    wrapper = name + "_wrapper"
    out_dir = name + "_out_dir"

    cc_library(
        name = wrapper,
        hdrs = ["@rules_rs//3rd_party/coreaudio-sys:coreaudio.h"],
        linkopts = select({
            "@platforms//os:ios": [
                "-framework",
                "AudioToolbox",
                "-framework",
                "CoreAudio",
                "-framework",
                "CoreMIDI",
                "-framework",
                "OpenAL",
            ],
            "@platforms//os:macos": [
                "-framework",
                "AudioToolbox",
                "-framework",
                "AudioUnit",
                "-framework",
                "CoreAudio",
                "-framework",
                "CoreMIDI",
                "-framework",
                "IOKit",
                "-framework",
                "OpenAL",
            ],
            "//conditions:default": [],
        }),
    )

    rust_bindgen(
        name = "coreaudio",
        bindgen_flags = [
            "--distrust-clang-mangling",
            "--no-layout-tests",
            "--with-derive-default",
        ],
        cc_lib = wrapper,
        header = "@rules_rs//3rd_party/coreaudio-sys:coreaudio.h",
    )

    copy_to_directory(
        name = out_dir,
        srcs = ["coreaudio"],
    )

    _coreaudio_sys_build_info(
        name = name,
        cc_lib = wrapper,
        out_dir = out_dir,
        visibility = ["//visibility:public"],
    )
