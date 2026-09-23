"""Select Cargo for the operating system and architecture running Bazel."""

load("@bazel_lib//lib:repo_utils.bzl", "repo_utils")

HOST_CARGO_ATTRS = {
    "%s_%s" % (os, arch): attr.label(
        allow_single_file = True,
        doc = "Existing Cargo executable for %s %s." % (os, arch),
    )
    for os in ["linux", "macos", "windows"]
    for arch in ["amd64", "arm64"]
}

def _host_cargo_repository_impl(rctx):
    platform = repo_utils.platform(rctx).replace("darwin_", "macos_")
    if platform not in HOST_CARGO_ATTRS:
        fail("Unsupported host Cargo platform: %s" % platform)
    cargo = getattr(rctx.attr, platform)
    if not cargo:
        fail("Set toolchains.host_cargo(%s = ...) to provide Cargo for this Bazel host" % platform)

    rctx.file("defs.bzl", 'RS_HOST_CARGO_LABEL = Label("%s")' % cargo)
    rctx.file("BUILD.bazel", 'exports_files(["defs.bzl"])')

    return rctx.repo_metadata(reproducible = True)

host_cargo_repository = repository_rule(
    implementation = _host_cargo_repository_impl,
    attrs = HOST_CARGO_ATTRS,
)
