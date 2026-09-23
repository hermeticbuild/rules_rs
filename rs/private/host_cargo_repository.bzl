"""Select Cargo for the operating system and architecture running Bazel."""

HOST_CARGO_ATTRS = {
    "%s_%s" % (os, arch): attr.label(
        allow_single_file = True,
        doc = "Existing Cargo executable for %s %s." % (os, arch),
    )
    for os in ["linux", "macos", "windows"]
    for arch in ["amd64", "arm64"]
}

def host_cargo_platform(os_name, arch):
    """Return the host Cargo attribute name for repository_ctx.os values.

    Args:
        os_name: The repository context's operating system name.
        arch: The repository context's architecture name.

    Returns:
        The normalized OS and architecture attribute name.
    """
    os_name = os_name.lower()
    if os_name.startswith("mac os"):
        os_name = "macos"
    elif os_name.startswith("windows"):
        os_name = "windows"
    arch = arch.lower()
    arch = {"x86_64": "amd64", "x64": "amd64", "aarch64": "arm64"}.get(arch, arch)
    return "%s_%s" % (os_name, arch)

def _host_cargo_repository_impl(rctx):
    cargo = rctx.attr.default_cargo
    if not cargo:
        platform = host_cargo_platform(rctx.os.name, rctx.os.arch)
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
    attrs = HOST_CARGO_ATTRS | {
        "default_cargo": attr.label(allow_single_file = True),
    },
)
