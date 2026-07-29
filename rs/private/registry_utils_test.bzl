load("@bazel_skylib//lib:unittest.bzl", "asserts", "unittest")
load(":registry_utils.bzl", "CRATES_IO_REGISTRY", "registry_download_url", "resolve_registry_source")

def _registry_source_resolution_impl(ctx):
    env = unittest.begin(ctx)
    crates_io = "registry+https://github.com/rust-lang/crates.io-index"
    source = "sparse+https://registry.example/index/"

    for lock_source, cargo_config, expected in [
        (None, {}, None),
        (crates_io, {}, CRATES_IO_REGISTRY),
        (source, {}, source),
        ("registry+" + source, {}, source),
        (
            crates_io,
            {"source": {
                "crates-io": {"replace-with": "artifactory"},
                "artifactory": {"registry": source},
            }},
            source,
        ),
        (
            crates_io,
            {
                "source": {"crates-io": {"replace-with": "artifactory"}},
                "registries": {"artifactory": {"index": source}},
            },
            source,
        ),
        (
            crates_io,
            {"source": {
                "crates-io": {"replace-with": "mirror"},
                "mirror": {"replace-with": "artifactory"},
                "artifactory": {"registry": source},
            }},
            source,
        ),
    ]:
        asserts.equals(env, expected, resolve_registry_source(lock_source, cargo_config))

    return unittest.end(env)

registry_source_resolution_test = unittest.make(_registry_source_resolution_impl)

def _registry_download_url_uses_directory_prefix_impl(ctx):
    env = unittest.begin(ctx)

    asserts.equals(
        env,
        "https://registry.example/My/Cr/my/cr/MyCrate-1.2.3-deadbeef.crate",
        registry_download_url(
            {"dl": "https://registry.example/{prefix}/{lowerprefix}/{crate}-{version}-{sha256-checksum}.crate"},
            "MyCrate",
            "1.2.3",
            "deadbeef",
        ),
    )
    for crate, prefix in [("a", "1"), ("ab", "2"), ("abc", "3/a"), ("cargo", "ca/rg")]:
        asserts.equals(
            env,
            "https://registry.example/" + prefix,
            registry_download_url({"dl": "https://registry.example/{prefix}"}, crate, "1.0.0", "checksum"),
        )
    return unittest.end(env)

registry_download_url_uses_directory_prefix_test = unittest.make(_registry_download_url_uses_directory_prefix_impl)

def registry_utils_tests():
    return unittest.suite(
        "registry_utils_tests",
        registry_source_resolution_test,
        registry_download_url_uses_directory_prefix_test,
    )
