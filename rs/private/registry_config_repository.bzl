load(":cargo_credentials.bzl", "load_cargo_credentials", "registry_auth_headers")

def _registry_config_repository_impl(rctx):
    # TODO(zbarsky): Is there a better way than fetching this in every crate repository?
    if rctx.attr.use_home_cargo_credentials:
        headers = registry_auth_headers(
            load_cargo_credentials(rctx, rctx.attr.cargo_config),
            rctx.attr.source,
        )
    else:
        headers = {}

    rctx.download(
        rctx.attr.source.removeprefix("sparse+") + "config.json",
        "config.json",
        headers = headers,
    )

    dl = json.decode(rctx.read("config.json"))["dl"]
    if not (
        "{crate}" in dl or
        "{version}" in dl or
        "{sha256-checksum}" in dl or
        "{prefix}" in dl or
        "{lowerprefix}" in dl
    ):
        dl += "/{crate}/{version}/download"

    rctx.file("dl", dl)
    rctx.file("BUILD.bazel", "exports_files(['dl'])")

    # Registry config can change upstream, so this repository is intentionally not reproducible.
    return rctx.repo_metadata(reproducible = False)

registry_config_repository = repository_rule(
    implementation = _registry_config_repository_impl,
    attrs = {
        "source": attr.string(mandatory = True),
        "cargo_config": attr.label(),
        "use_home_cargo_credentials": attr.bool(),
    },
)
