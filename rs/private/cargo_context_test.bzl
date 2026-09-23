"""Test Cargo setting changes across generated and workspace crates."""

load("@bazel_skylib//lib:unittest.bzl", "asserts", "unittest")

# buildifier: disable=bzl-visibility
load("@rules_rust//rust/private:per_crate_flag_trim.bzl", "CARGO_TARGET_TRIPLE_SETTING", "trim_crate_settings")

_LINUX = "x86_64-unknown-linux-gnu"
_MACOS = "aarch64-apple-darwin"
_RUSTC_SETTING = "@rules_rust//rust/settings:per_crate_rustc_flag"

def _settings(cargo_target_triple = ""):
    return {
        _RUSTC_SETTING: ["helper@--cfg=custom"],
        CARGO_TARGET_TRIPLE_SETTING: cargo_target_triple,
    }

def _cargo_target_triple_mapping_impl(ctx):
    env = unittest.begin(ctx)
    for incoming, cargo_target_triple_map, expected in [
        (_MACOS, {_MACOS: ""}, ""),
        (_MACOS, {}, _MACOS),
        (_MACOS, {_LINUX: ""}, _MACOS),
        ("", {"": _LINUX}, _LINUX),
    ]:
        settings = _settings(incoming)
        attr = struct(cargo_target_triple_map = cargo_target_triple_map, skip_per_crate_rustc_flags = False)
        result = trim_crate_settings(settings, attr)
        asserts.equals(env, _settings(expected), result)
        asserts.equals(env, result, trim_crate_settings(result, attr))
        asserts.equals(env, _settings(incoming), settings)
    reset = trim_crate_settings(_settings(), struct(cargo_target_triple_map = {}, skip_per_crate_rustc_flags = True))
    asserts.equals(env, _settings() | {_RUSTC_SETTING: []}, reset)
    return unittest.end(env)

cargo_target_triple_mapping_test = unittest.make(_cargo_target_triple_mapping_impl)

def cargo_context_tests():
    return unittest.suite(
        "cargo_context_tests",
        cargo_target_triple_mapping_test,
    )
