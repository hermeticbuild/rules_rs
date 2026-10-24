load("@bazel_skylib//lib:unittest.bzl", "analysistest", "asserts", "unittest")
load(":registry_utils.bzl", "CRATES_IO_LOCK_SOURCE", "CRATES_IO_REGISTRY", "registry_download_template", "registry_download_url", "resolve_crates_io_source", "resolve_registry_source")

def _registry_source_resolution_impl(ctx):
    env = unittest.begin(ctx)
    source = "sparse+https://registry.example/index/"

    for lock_source, crates_io_source, expected in [
        (None, source, None),
        (CRATES_IO_LOCK_SOURCE, CRATES_IO_REGISTRY, CRATES_IO_REGISTRY),
        (CRATES_IO_LOCK_SOURCE, source, source),
        (source, CRATES_IO_REGISTRY, source),
        ("registry+" + source, CRATES_IO_REGISTRY, source),
    ]:
        asserts.equals(env, expected, resolve_registry_source(lock_source, crates_io_source))

    asserts.equals(env, CRATES_IO_REGISTRY, resolve_crates_io_source({}))
    for cargo_config in [
        {"source": {
            "crates-io": {"replace-with": "artifactory"},
            "artifactory": {"registry": source},
            "unrelated": {"replace-with": 42},
        }},
        {
            "source": {"crates-io": {"replace-with": "artifactory"}},
            "registries": {"artifactory": {"index": source}},
        },
        {"source": {
            "crates-io": {"replace-with": "mirror"},
            "mirror": {"replace-with": "artifactory"},
            "artifactory": {"registry": source},
        }},
    ]:
        asserts.equals(env, source, resolve_crates_io_source(cargo_config))

    return unittest.end(env)

registry_source_resolution_test = unittest.make(_registry_source_resolution_impl)

def _invalid_config_impl(ctx):
    if ctx.attr.kind == "cargo":
        resolve_crates_io_source({"source": {"crates-io": {"replace-with": 42}}})
    else:
        registry_download_template({"dl": 42})
    return []

_invalid_config = rule(
    implementation = _invalid_config_impl,
    attrs = {"kind": attr.string(mandatory = True, values = ["cargo", "registry"])},
)

def _invalid_config_test_impl(ctx):
    env = analysistest.begin(ctx)
    asserts.expect_failure(env, ctx.attr.expected_error)
    return analysistest.end(env)

_invalid_config_test = analysistest.make(
    _invalid_config_test_impl,
    attrs = {"expected_error": attr.string(mandatory = True)},
    expect_failure = True,
)

def _invalid_config_case(name, kind, expected_error):
    target = name + "_subject"
    _invalid_config(name = target, kind = kind, tags = ["manual"])
    _invalid_config_test(name = name, expected_error = expected_error, target_under_test = ":" + target)

def _invalid_cargo_config_case(name):
    _invalid_config_case(name, "cargo", "Cargo configuration source.crates-io.replace-with must be a string")

def _invalid_registry_config_case(name):
    _invalid_config_case(name, "registry", "Cargo registry config.json field dl must be a string")

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
        _invalid_cargo_config_case,
        _invalid_registry_config_case,
    )
