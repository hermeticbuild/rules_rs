def _toolchains_repository_impl(rctx):
    rctx.file(
        "BUILD.bazel",
        """\
load("@rules_rs//rs/toolchains:declare_rust_analyzer_toolchains.bzl", "declare_rust_analyzer_toolchains")
load("@rules_rs//rs/toolchains:declare_rustc_toolchains.bzl", "declare_rustc_toolchains")
load("@rules_rs//rs/toolchains:declare_rustfmt_toolchains.bzl", "declare_rustfmt_toolchains")

config_setting(
    name = "selected_family",
    flag_values = {{
        "@rules_rs//rs/toolchains/family:family": {toolchain_family},
    }},
)

declare_rustc_toolchains(
    version = {version},
    edition = {edition},
    include_rustc_dev = {include_rustc_dev},
    extra_rustc_flags = {extra_rustc_flags},
    extra_exec_rustc_flags = {extra_exec_rustc_flags},
    toolchain_family_setting = ":selected_family",
)

declare_rustfmt_toolchains(
    version = {version},
    rustfmt_version = {rustfmt_version},
    edition = {edition},
    toolchain_family_setting = ":selected_family",
)

declare_rust_analyzer_toolchains(
    version = {version},
    rust_analyzer_version = {rust_analyzer_version},
    toolchain_family_setting = ":selected_family",
)
""".format(
            version = repr(rctx.attr.version),
            rustfmt_version = repr(rctx.attr.rustfmt_version),
            rust_analyzer_version = repr(rctx.attr.rust_analyzer_version),
            edition = repr(rctx.attr.edition),
            include_rustc_dev = repr(rctx.attr.include_rustc_dev),
            extra_rustc_flags = repr(rctx.attr.extra_rustc_flags),
            extra_exec_rustc_flags = repr(rctx.attr.extra_exec_rustc_flags),
            toolchain_family = repr(rctx.attr.toolchain_family),
        ),
    )

    return rctx.repo_metadata(reproducible = True)

toolchains_repository = repository_rule(
    implementation = _toolchains_repository_impl,
    attrs = {
        "version": attr.string(mandatory = True),
        "rustfmt_version": attr.string(mandatory = True),
        "rust_analyzer_version": attr.string(mandatory = True),
        "edition": attr.string(mandatory = True),
        "include_rustc_dev": attr.bool(),
        "extra_rustc_flags": attr.string_list_dict(),
        "extra_exec_rustc_flags": attr.string_list_dict(),
        "toolchain_family": attr.string(mandatory = True),
    },
)
