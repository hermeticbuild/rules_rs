"""Miri toolchain rules."""

load("//rs/experimental/miri/private:providers.bzl", "MiriSysrootInfo")

MIRI_TOOLCHAIN_TYPE = str(Label("//rs/experimental/miri:toolchain_type"))
MIRI_SYSROOT_TOOLCHAIN_TYPE = str(Label("//rs/experimental/miri:sysroot_toolchain_type"))

_COMMON_ATTRS = {
    "exec_triple": attr.string(mandatory = True),
    "miri": attr.label(allow_single_file = True, cfg = "exec", mandatory = True),
    "process_wrapper": attr.label(
        default = Label("@rules_rust//util/process_wrapper"),
        cfg = "exec",
        executable = True,
        doc = "Executable wrapper used to apply rustc env files and execute Miri-as-rustc.",
    ),
    "rustc_lib": attr.label(allow_files = True, cfg = "exec", mandatory = True),
    "target_triple": attr.string(mandatory = True),
}

def _all_files(ctx, direct = [], transitive = []):
    return depset(
        [ctx.file.miri] + direct,
        transitive = [
            depset(ctx.files.rustc_lib),
        ] + transitive,
    )

def _toolchain_info(ctx, all_files, extra = None):
    fields = {
        "all_files": all_files,
        "exec_triple": ctx.attr.exec_triple,
        "miri": ctx.file.miri,
        "process_wrapper": ctx.executable.process_wrapper,
        "target_triple": ctx.attr.target_triple,
    }
    fields.update(extra or {})
    return platform_common.ToolchainInfo(**fields)

def _miri_toolchain_impl(ctx):
    source_sysroot = ctx.attr.source_sysroot[MiriSysrootInfo]
    if source_sysroot.target_triple != ctx.attr.target_triple:
        fail("source_sysroot target triple {} does not match toolchain target triple {}".format(
            source_sysroot.target_triple,
            ctx.attr.target_triple,
        ))
    host_source_sysroot = ctx.attr.host_source_sysroot[MiriSysrootInfo]
    if host_source_sysroot.target_triple != ctx.attr.exec_triple:
        fail("host_source_sysroot target triple {} does not match toolchain execution triple {}".format(
            host_source_sysroot.target_triple,
            ctx.attr.exec_triple,
        ))

    return [
        _toolchain_info(ctx, _all_files(ctx, direct = [source_sysroot.sysroot]), {
            "host_miri_sysroot": host_source_sysroot.sysroot,
            "miri_sysroot": source_sysroot.sysroot,
        }),
    ]

miri_toolchain = rule(
    implementation = _miri_toolchain_impl,
    attrs = _COMMON_ATTRS | {
        "host_source_sysroot": attr.label(
            cfg = "exec",
            providers = [MiriSysrootInfo],
            mandatory = True,
            doc = "Bazel-prepared Miri sysroot for host-mode rustc work such as proc macros.",
        ),
        "source_sysroot": attr.label(
            providers = [MiriSysrootInfo],
            mandatory = True,
            doc = "Bazel-prepared Miri sysroot.",
        ),
    },
)

def _miri_sysroot_toolchain_impl(ctx):
    return [
        _toolchain_info(ctx, _all_files(ctx, transitive = [depset(ctx.files.rustc_srcs)]), {
            "rustc_srcs": ctx.files.rustc_srcs,
        }),
    ]

miri_sysroot_toolchain = rule(
    implementation = _miri_sysroot_toolchain_impl,
    attrs = _COMMON_ATTRS | {
        "rustc_srcs": attr.label(allow_files = True, mandatory = True),
    },
)
