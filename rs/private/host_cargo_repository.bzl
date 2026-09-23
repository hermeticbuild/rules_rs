"""Expose the selected host Cargo label."""

def _host_cargo_repository_impl(rctx):
    rctx.file("defs.bzl", 'RS_HOST_CARGO_LABEL = Label("%s")' % rctx.attr.cargo)
    rctx.file("BUILD.bazel", 'exports_files(["defs.bzl"])')

    return rctx.repo_metadata(reproducible = True)

host_cargo_repository = repository_rule(
    implementation = _host_cargo_repository_impl,
    attrs = {"cargo": attr.label(allow_single_file = True, mandatory = True)},
)
