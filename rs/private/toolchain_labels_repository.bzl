"""Resolve compiler component labels in the toolchains extension's repositories."""

def _toolchain_labels_repository_impl(rctx):
    # type: (...) -> repo_metadata
    # TODO(https://github.com/bazelbuild/bazel/issues/32020): Use native return annotations
    # when Bazel exposes repo_metadata.
    rctx.file(
        "defs.bzl",
        "def rust_toolchain_component_label(label):\n    return Label(label)\n",
    )
    rctx.file("BUILD.bazel", 'exports_files(["defs.bzl"])')
    return rctx.repo_metadata(reproducible = True)

toolchain_labels_repository = repository_rule(
    implementation = _toolchain_labels_repository_impl,
)
