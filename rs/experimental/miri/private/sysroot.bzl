"""Miri sysroot rules."""

load("@bazel_lib//lib:copy_to_directory.bzl", "copy_to_directory_bin_action")
load("//rs/experimental/miri/private:compile.bzl", "miri_sysroot_compile_aspect")
load("//rs/experimental/miri/private:providers.bzl", "MiriCrateInfo", "MiriSysrootInfo")
load("//rs/experimental/miri/private:toolchain.bzl", "MIRI_SYSROOT_TOOLCHAIN_TYPE")

_COPY_TO_DIRECTORY_TOOLCHAIN_TYPE = "@bazel_lib//lib:copy_to_directory_toolchain_type"

def _repository_relative_path(file):
    if file.short_path.startswith("../"):
        return file.short_path[file.short_path.find("/", 3) + 1:]
    return file.short_path

def _miri_sysroot_impl(ctx):
    toolchain = ctx.toolchains[MIRI_SYSROOT_TOOLCHAIN_TYPE]
    srcs_by_path = {src.short_path: src for src in ctx.files.srcs}

    for root in ctx.attr.roots:
        if MiriCrateInfo not in root:
            fail("{} must provide MiriCrateInfo; only Rust library roots can form a Miri sysroot".format(root.label))
        for output in root[MiriCrateInfo].target.transitive_outputs.to_list():
            srcs_by_path[output.short_path] = output

    if not srcs_by_path:
        fail("miri_sysroot requires at least one src or root")

    sysroot = ctx.actions.declare_directory(ctx.label.name)
    lib_dir = "lib/rustlib/{}/lib".format(toolchain.target_triple)
    srcs = [srcs_by_path[path] for path in sorted(srcs_by_path.keys())]
    replace_prefixes = {}
    basenames = set()
    for src in srcs:
        if src.basename in basenames:
            fail("Miri sysroot input basename '{}' is not unique".format(src.basename))
        basenames.add(src.basename)
        replace_prefixes[_repository_relative_path(src)] = "{}/{}".format(lib_dir, src.basename)

    copy_to_directory_bin_action(
        ctx,
        name = ctx.label.name,
        dst = sysroot,
        copy_to_directory_bin = ctx.toolchains[_COPY_TO_DIRECTORY_TOOLCHAIN_TYPE].copy_to_directory_info.bin,
        files = srcs,
        root_paths = [],
        include_external_repositories = ["**"],
        replace_prefixes = replace_prefixes,
        hardlink = "off",
    )

    return [
        MiriSysrootInfo(
            sysroot = sysroot,
            target_triple = toolchain.target_triple,
        ),
        DefaultInfo(
            files = depset([sysroot]),
            runfiles = ctx.runfiles([sysroot]),
        ),
    ]

miri_sysroot = rule(
    implementation = _miri_sysroot_impl,
    attrs = {
        "roots": attr.label_list(
            aspects = [miri_sysroot_compile_aspect],
            doc = "Root Rust libraries from the Rust source graph whose Miri-compiled transitive outputs form the sysroot.",
        ),
        "srcs": attr.label_list(
            allow_files = True,
            doc = "Rust sysroot crate artifacts to place under lib/rustlib/<target>/lib.",
        ),
    },
    toolchains = [
        MIRI_SYSROOT_TOOLCHAIN_TYPE,
        _COPY_TO_DIRECTORY_TOOLCHAIN_TYPE,
    ],
)
