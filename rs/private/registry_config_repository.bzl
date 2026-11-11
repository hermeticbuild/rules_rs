load(":cargo_credentials.bzl", "repository_registry_auth_headers")
load(":registry_utils.bzl", "registry_download_template")

def _registry_config_repository_impl(rctx):
    rctx.download(
        rctx.attr.source.removeprefix("sparse+") + "config.json",
        "config.json",
        headers = repository_registry_auth_headers(rctx),
    )

    rctx.file("dl", registry_download_template(json.decode(rctx.read("config.json"))))
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
