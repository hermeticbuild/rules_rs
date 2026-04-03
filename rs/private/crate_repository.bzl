load("@bazel_features//:features.bzl", "bazel_features")
load("@bazel_tools//tools/build_defs/repo:cache.bzl", "get_default_canonical_id")
load("@bazel_tools//tools/build_defs/repo:utils.bzl", "patch")
load(":cargo_credentials.bzl", "load_cargo_credentials", "registry_auth_headers")
load(":repository_utils.bzl", "common_attrs", "generate_build_file")
load(":toml2json.bzl", "run_toml2json")

def _crate_repository_impl(rctx):
    # TODO(zbarsky): Is there a better way than fetching this in every crate repository?
    if rctx.attr.use_home_cargo_credentials:
        headers = registry_auth_headers(
            load_cargo_credentials(rctx, rctx.attr.cargo_config),
            rctx.attr.source,
        )
    else:
        headers = {}

    rctx.download_and_extract(
        rctx.attr.url,
        type = "tar.gz",
        canonical_id = get_default_canonical_id(rctx, urls = [rctx.attr.url]),
        headers = headers,
        strip_prefix = rctx.attr.strip_prefix,
        sha256 = rctx.attr.checksum,
    )

    patch(rctx)

    cargo_toml = run_toml2json(rctx, "Cargo.toml")

    rctx.file("BUILD.bazel", generate_build_file(rctx, cargo_toml, purl_qualifiers = rctx.attr.sbom_extra_qualifiers))

    return rctx.repo_metadata(reproducible = True)

crate_repository = repository_rule(
    implementation = _crate_repository_impl,
    attrs = {
        "url": attr.string(mandatory = True),
        "cargo_config": attr.label(),
        "source": attr.string(),
        "use_home_cargo_credentials": attr.bool(),
        "checksum": attr.string(),
        "sbom_extra_qualifiers": attr.string_dict(),
    } | common_attrs,
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

    rctx.file("BUILD.bazel", generate_build_file(rctx, cargo_toml))

    return rctx.repo_metadata(
        reproducible = bazel_features.external_deps.repo_rules_relativize_symlinks,
    )

local_crate_repository = repository_rule(
    implementation = _local_crate_repository_impl,
    attrs = {
        "path": attr.string(mandatory = True),
    } | common_attrs,
)
