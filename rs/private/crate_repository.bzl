load("@bazel_tools//tools/build_defs/repo:cache.bzl", "get_default_canonical_id")
load("@bazel_tools//tools/build_defs/repo:utils.bzl", "get_auth", "patch")
load(":cargo_credentials.bzl", "load_cargo_credentials", "registry_auth_headers")
load(":registry_utils.bzl", "registry_download_url_from_template")
load(":repository_utils.bzl", "cargo_build_file_values", "common_attrs", "crate_identity_attr", "render_build_file_content")
load(":toml2json.bzl", "run_toml2json")

def _cargo_purl(package_name, version, qualifiers = {}):
    purl = "pkg:cargo/{}@{}".format(package_name, version)
    if qualifiers:
        purl += "?" + "&".join([
            "{}={}".format(key, qualifiers[key])
            for key in sorted(qualifiers)
        ])
    return purl

def _generate_build_file(rctx, cargo_toml, purl_qualifiers = {}, package_path = ""):
    cargo = cargo_build_file_values(rctx, cargo_toml, rctx.attr.gen_binaries, package_path = package_path)
    package = cargo_toml["package"]
    values = dict(cargo.values)
    values.update({
        "name": repr(package["name"]),
        "purl": repr(_cargo_purl(package["name"], package["version"], purl_qualifiers)),
        "version": repr(package["version"]),
    })
    return render_build_file_content(rctx, rctx.attr, values, bazel_metadata = cargo.bazel_metadata)

def _crate_repository_impl(rctx):
    # TODO(zbarsky): Is there a better way than fetching this in every crate repository?
    if rctx.attr.registry_auth_required and rctx.attr.use_home_cargo_credentials:
        headers = registry_auth_headers(
            load_cargo_credentials(rctx, rctx.attr.cargo_config),
            rctx.attr.source,
        )
    else:
        headers = {}

    crate_name = rctx.attr.crate_name
    version = rctx.attr.version
    sha256 = rctx.attr.checksum

    dl = rctx.attr.registry_dl

    url = registry_download_url_from_template(dl, crate_name, version, sha256)

    auth = {}
    if not headers:
        auth = get_auth(rctx, [url])

    rctx.download_and_extract(
        url,
        type = "tar.gz",
        canonical_id = get_default_canonical_id(rctx, urls = [url]),
        headers = headers,
        strip_prefix = "%s-%s" % (crate_name, version),
        sha256 = sha256,
        auth = auth,
    )

    patch(rctx)

    cargo_toml = run_toml2json(rctx, "Cargo.toml")

    rctx.file("BUILD.bazel", _generate_build_file(rctx, cargo_toml, purl_qualifiers = rctx.attr.sbom_extra_qualifiers))

    return rctx.repo_metadata(reproducible = True)

# Keep repository-only attrs classified at their declaration site. Compilation
# attrs live in `common_attrs`, whose policy map is consumed by the coalescer.
# These fields either define/verify the fetched source or select a hub-local
# transport for fetching identical verified bytes.
_SOURCE_IDENTITY_ATTRS = {
    "checksum": attr.string(),
    "crate_name": attr.string(mandatory = True),
    "sbom_extra_qualifiers": attr.string_dict(),
    "source": attr.string(),
    "version": attr.string(mandatory = True),
}
_HUB_LOCAL_FETCH_ATTRS = {
    "cargo_config": attr.label(),
    "registry_auth_required": attr.bool(),
    "registry_dl": attr.string(mandatory = True),
    "use_home_cargo_credentials": attr.bool(),
}

crate_repository = repository_rule(
    implementation = _crate_repository_impl,
    attrs = _SOURCE_IDENTITY_ATTRS | _HUB_LOCAL_FETCH_ATTRS | crate_identity_attr | common_attrs,
)

def _local_crate_repository_impl(rctx):
    if rctx.attr.strip_prefix:
        fail("strip_prefix not implemented")

    root = rctx.path(rctx.attr.path)
    if not root.exists:
        fail("crate path %s does not exist" % rctx.attr.path)

    for entry in root.readdir():
        rctx.symlink(entry, entry.basename)

    patch(rctx)

    cargo_toml = run_toml2json(rctx, "Cargo.toml")

    rctx.file("BUILD.bazel", _generate_build_file(rctx, cargo_toml))

    # Symlinks into the main workspace get replanted by Bazel >= 9.0.1 as
    # relative `..\_main\...` paths before reproducible repos enter the
    # contents cache. On Windows those paths dangle from the action
    # execroot (no `execroot/_main/external/_main`), so actions fail to
    # read the crate sources. Marking non-reproducible skips replanting
    # and keeps the original absolute symlinks, which resolve from both
    # views. See https://github.com/bazelbuild/bazel/issues/29515.
    return rctx.repo_metadata(reproducible = False)

local_crate_repository = repository_rule(
    implementation = _local_crate_repository_impl,
    attrs = {
        "path": attr.string(mandatory = True),
    } | common_attrs,
)
