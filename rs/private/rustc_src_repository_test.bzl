"""Tests for the Rust compiler source repository."""

load("@bazel_skylib//lib:unittest.bzl", "asserts", "unittest")
load(":rustc_src_repository.bzl", "rustc_src_repository_test_helpers")

visibility("private")

def _strip_prefix_test_impl(ctx):
    env = unittest.begin(ctx)
    asserts.equals(
        env,
        "rustc-1.78.0-src/src",
        rustc_src_repository_test_helpers.strip_prefix("1.78.0"),
    )
    asserts.equals(
        env,
        "rustc-1.79.0-src",
        rustc_src_repository_test_helpers.strip_prefix("1.79.0"),
    )
    asserts.equals(
        env,
        "rustc-nightly-src",
        rustc_src_repository_test_helpers.strip_prefix("nightly"),
    )
    return unittest.end(env)

_strip_prefix_test = unittest.make(_strip_prefix_test_impl)

def rustc_src_repository_tests():
    unittest.suite(
        "rustc_src_repository_tests",
        _strip_prefix_test,
    )
