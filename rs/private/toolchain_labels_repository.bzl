"""Resolve compiler component labels in the toolchains extension's repositories."""

def _toolchain_labels_repository_impl(rctx):
    rctx.file(
        "defs.bzl",
        "def rust_toolchain_component_label(label):\n    return Label(label)\n",
    )
    rctx.file("BUILD.bazel", 'exports_files(["defs.bzl"])')
    return rctx.repo_metadata(reproducible = True)

toolchain_labels_repository = repository_rule(
    implementation = _toolchain_labels_repository_impl,
)
