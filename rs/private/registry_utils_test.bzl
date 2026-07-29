load("@bazel_skylib//lib:unittest.bzl", "asserts", "unittest")
load(":registry_utils.bzl", "CRATES_IO_REGISTRY", "registry_download_url", "resolve_registry_source")

def _default_crates_io_registry_source_impl(ctx):
    env = unittest.begin(ctx)

    asserts.equals(
        env,
        CRATES_IO_REGISTRY,
        resolve_registry_source("registry+https://github.com/rust-lang/crates.io-index"),
    )
    return unittest.end(env)

default_crates_io_registry_source_test = unittest.make(_default_crates_io_registry_source_impl)

def _named_sparse_registry_source_impl(ctx):
    env = unittest.begin(ctx)

    source = "sparse+https://registry.example/index/"
    asserts.equals(env, source, resolve_registry_source(source))
    asserts.equals(env, source, resolve_registry_source("registry+" + source))
    return unittest.end(env)

named_sparse_registry_source_test = unittest.make(_named_sparse_registry_source_impl)

def _replacement_sparse_registry_source_impl(ctx):
    env = unittest.begin(ctx)

    source = "sparse+https://registry.example/index/"
    cargo_config = {
        "source": {
            "crates-io": {"replace-with": "artifactory"},
            "artifactory": {"registry": source},
        },
    }
    asserts.equals(
        env,
        source,
        resolve_registry_source("registry+https://github.com/rust-lang/crates.io-index", cargo_config),
    )
    return unittest.end(env)

replacement_sparse_registry_source_test = unittest.make(_replacement_sparse_registry_source_impl)

def _replacement_named_registry_source_impl(ctx):
    env = unittest.begin(ctx)

    source = "sparse+https://registry.example/index/"
    cargo_config = {
        "source": {
            "crates-io": {"replace-with": "artifactory"},
        },
        "registries": {
            "artifactory": {"index": source},
        },
    }
    asserts.equals(
        env,
        source,
        resolve_registry_source("registry+https://github.com/rust-lang/crates.io-index", cargo_config),
    )
    return unittest.end(env)

replacement_named_registry_source_test = unittest.make(_replacement_named_registry_source_impl)

def _chained_replacement_registry_source_impl(ctx):
    env = unittest.begin(ctx)

    source = "sparse+https://registry.example/index/"
    cargo_config = {
        "source": {
            "crates-io": {"replace-with": "mirror"},
            "mirror": {"replace-with": "artifactory"},
            "artifactory": {"registry": source},
        },
    }
    asserts.equals(
        env,
        source,
        resolve_registry_source("registry+https://github.com/rust-lang/crates.io-index", cargo_config),
    )
    return unittest.end(env)

chained_replacement_registry_source_test = unittest.make(_chained_replacement_registry_source_impl)

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
        default_crates_io_registry_source_test,
        named_sparse_registry_source_test,
        replacement_sparse_registry_source_test,
        replacement_named_registry_source_test,
        chained_replacement_registry_source_test,
        registry_download_url_uses_directory_prefix_test,
    )
