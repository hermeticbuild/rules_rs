def _toolchains_repository_impl(rctx):
    rctx.file(
        "rustc/version.bzl",
        "RUST_VERSION = {}\n".format(repr(rctx.attr.version)),
    )
    rctx.file(
        "rustc/component_labels.bzl",
        "def rust_toolchain_component_label(label):\n    return Label(label)\n",
    )
    rctx.file(
        "rustc/BUILD.bazel",
        """\
load("@rules_rs//rs/toolchains:declare_rustc_toolchains.bzl", "declare_rustc_toolchains")

exports_files(["component_labels.bzl", "version.bzl"])

declare_rustc_toolchains(
    name = "default",
    version = {version},
    edition = {edition},
    extra_rustc_flags = {extra_rustc_flags},
    extra_exec_rustc_flags = {extra_exec_rustc_flags},
    target_triples = {target_triples},
)
""".format(
            version = repr(rctx.attr.version),
            edition = repr(rctx.attr.edition),
            extra_rustc_flags = repr(rctx.attr.extra_rustc_flags),
            extra_exec_rustc_flags = repr(rctx.attr.extra_exec_rustc_flags),
            target_triples = repr(rctx.attr.target_triples),
        ),
    )

    rctx.file(
        "rustfmt/BUILD.bazel",
        """\
load("@rules_rs//rs/toolchains:declare_rustfmt_toolchains.bzl", "declare_rustfmt_toolchains")

declare_rustfmt_toolchains(
    version = {version},
    rustfmt_version = {rustfmt_version},
    edition = {edition},
)
""".format(
            version = repr(rctx.attr.version),
            rustfmt_version = repr(rctx.attr.rustfmt_version),
            edition = repr(rctx.attr.edition),
        ),
    )

    rctx.file(
        "rust-analyzer/BUILD.bazel",
        """\
load("@rules_rs//rs/toolchains:declare_rust_analyzer_toolchains.bzl", "declare_rust_analyzer_toolchains")

declare_rust_analyzer_toolchains(
    version = {version},
    rust_analyzer_version = {rust_analyzer_version},
)
""".format(
            version = repr(rctx.attr.version),
            rust_analyzer_version = repr(rctx.attr.rust_analyzer_version),
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
        "extra_rustc_flags": attr.string_list_dict(),
        "extra_exec_rustc_flags": attr.string_list_dict(),
        "target_triples": attr.string_list(mandatory = True),
    },
)
