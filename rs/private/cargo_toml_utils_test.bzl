"""Tests for Cargo.toml manifest helpers."""

load("@bazel_skylib//lib:unittest.bzl", "asserts", "unittest")
load(":cargo_toml_utils.bzl", "cargo_toml_is_proc_macro")

def _cargo_toml_is_proc_macro_test_impl(ctx):
    env = unittest.begin(ctx)

    asserts.true(env, cargo_toml_is_proc_macro({"lib": {"proc-macro": True}}))
    asserts.true(env, cargo_toml_is_proc_macro({"lib": {"proc_macro": True}}))
    asserts.true(env, cargo_toml_is_proc_macro({"lib": {"crate-type": ["proc-macro"]}}))
    asserts.true(env, cargo_toml_is_proc_macro({"lib": {"crate_type": ["proc-macro"]}}))

    asserts.false(env, cargo_toml_is_proc_macro({}))
    asserts.false(env, cargo_toml_is_proc_macro({"lib": {}}))
    asserts.false(env, cargo_toml_is_proc_macro({"lib": {"proc-macro": False}}))
    asserts.false(env, cargo_toml_is_proc_macro({"lib": {"crate-type": ["cdylib", "rlib"]}}))

    return unittest.end(env)

_cargo_toml_is_proc_macro_test = unittest.make(_cargo_toml_is_proc_macro_test_impl)

def cargo_toml_utils_tests():
    _cargo_toml_is_proc_macro_test(
        name = "cargo_toml_is_proc_macro_test",
    )

    native.test_suite(
        name = "cargo_toml_utils_tests",
        tests = [":cargo_toml_is_proc_macro_test"],
    )
