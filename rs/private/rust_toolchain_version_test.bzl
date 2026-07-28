load("@bazel_skylib//lib:unittest.bzl", "asserts", "unittest")
load(":rust_toolchain_version.bzl", "rust_toolchain_version_metadata")

def _stable_version_metadata_impl(ctx):
    env = unittest.begin(ctx)

    metadata = rust_toolchain_version_metadata("1.92.0")
    asserts.equals(env, "1.92.0", metadata.version)
    asserts.equals(env, "stable", metadata.channel)
    asserts.true(env, metadata.has_rust_objcopy)
    asserts.equals(env, "", metadata.iso_date)
    asserts.false(env, rust_toolchain_version_metadata("1.78.0").has_rust_objcopy)
    asserts.true(env, rust_toolchain_version_metadata("1.84.0").has_rust_objcopy)
    asserts.true(env, rust_toolchain_version_metadata("2.0.0").has_rust_objcopy)

    return unittest.end(env)

def _nightly_version_metadata_is_descriptive_impl(ctx):
    env = unittest.begin(ctx)

    metadata = rust_toolchain_version_metadata("nightly/2026-06-24")
    asserts.equals(env, "nightly", metadata.version)
    asserts.equals(env, "nightly", metadata.channel)
    asserts.true(env, metadata.has_rust_objcopy)
    asserts.equals(env, "2026-06-24", metadata.iso_date)
    asserts.false(
        env,
        rust_toolchain_version_metadata("nightly/2024-11-06").has_rust_objcopy,
    )
    asserts.true(
        env,
        rust_toolchain_version_metadata("nightly/2024-11-07").has_rust_objcopy,
    )

    return unittest.end(env)

def _beta_version_metadata_is_descriptive_impl(ctx):
    env = unittest.begin(ctx)

    metadata = rust_toolchain_version_metadata("beta/2026-06-24")
    asserts.equals(env, "beta", metadata.version)
    asserts.equals(env, "beta", metadata.channel)
    asserts.true(env, metadata.has_rust_objcopy)
    asserts.equals(env, "2026-06-24", metadata.iso_date)
    asserts.false(
        env,
        rust_toolchain_version_metadata("beta/2024-11-23").has_rust_objcopy,
    )
    asserts.true(
        env,
        rust_toolchain_version_metadata("beta/2024-11-27").has_rust_objcopy,
    )

    return unittest.end(env)

stable_version_metadata_test = unittest.make(_stable_version_metadata_impl)
nightly_version_metadata_is_descriptive_test = unittest.make(_nightly_version_metadata_is_descriptive_impl)
beta_version_metadata_is_descriptive_test = unittest.make(_beta_version_metadata_is_descriptive_impl)

def rust_toolchain_version_metadata_tests():
    return unittest.suite(
        "rust_toolchain_version_metadata_tests",
        stable_version_metadata_test,
        nightly_version_metadata_is_descriptive_test,
        beta_version_metadata_is_descriptive_test,
    )
