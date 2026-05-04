def _host_tools_repository_impl(rctx):
    rctx.file("defs.bzl", 'RS_HOST_CARGO_LABEL = Label("%s")\n' % rctx.attr.host_cargo)
    rctx.file("BUILD.bazel", 'exports_files(["defs.bzl"])')

    return rctx.repo_metadata(reproducible = True)

host_tools_repository = repository_rule(
    implementation = _host_tools_repository_impl,
    attrs = {
        "host_cargo": attr.label(allow_single_file = True, mandatory = True),
    },
)
