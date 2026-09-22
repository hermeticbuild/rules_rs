"""Test Cargo setting changes across generated and workspace crates."""

load("@bazel_skylib//lib:unittest.bzl", "asserts", "unittest")

# buildifier: disable=bzl-visibility
load("@rules_rust//rust/private:per_crate_flag_trim.bzl", "CARGO_TARGET_TRIPLE_SETTING", "CRATE_SETTINGS", "trim_crate_settings")

_LINUX = "x86_64-unknown-linux-gnu"
_MACOS = "aarch64-apple-darwin"
_RUSTC_SETTING = "@rules_rust//rust/settings:per_crate_rustc_flag"

def _settings(context = ""):
    return {
        _RUSTC_SETTING: ["helper@--cfg=custom"],
        CARGO_TARGET_TRIPLE_SETTING: context,
    }

def _generated_context_normalization_impl(ctx):
    env = unittest.begin(ctx)
    settings = _settings(_MACOS)
    attr = struct(cargo_contexts = {_MACOS: _LINUX, _LINUX: _LINUX}, skip_per_crate_rustc_flags = False)
    result = trim_crate_settings(settings, attr)
    asserts.equals(env, sorted(CRATE_SETTINGS), sorted(result))
    asserts.equals(env, _settings(_LINUX), result)
    asserts.equals(env, result, trim_crate_settings(result, attr))
    reset = trim_crate_settings(result, struct(cargo_contexts = {_LINUX: ""}, skip_per_crate_rustc_flags = True))
    asserts.equals(env, _settings() | {_RUSTC_SETTING: []}, reset)
    asserts.equals(env, _settings(_MACOS), settings)
    return unittest.end(env)

def _workspace_preserves_cargo_settings_impl(ctx):
    env = unittest.begin(ctx)
    settings = _settings(_MACOS)
    asserts.equals(env, settings, trim_crate_settings(settings, struct(cargo_contexts = {}, skip_per_crate_rustc_flags = False)))
    asserts.equals(env, settings, trim_crate_settings(settings, struct(cargo_contexts = {_LINUX: ""}, skip_per_crate_rustc_flags = False)))
    return unittest.end(env)

def _build_script_enters_execution_context_impl(ctx):
    env = unittest.begin(ctx)
    attr = struct(cargo_contexts = {"": _LINUX}, skip_per_crate_rustc_flags = False)
    result = trim_crate_settings(_settings(), attr)
    asserts.equals(env, _settings(_LINUX), result)
    asserts.equals(env, result, trim_crate_settings(result, attr))
    return unittest.end(env)

generated_context_normalization_test = unittest.make(_generated_context_normalization_impl)
workspace_preserves_cargo_settings_test = unittest.make(_workspace_preserves_cargo_settings_impl)
build_script_enters_execution_context_test = unittest.make(_build_script_enters_execution_context_impl)

def cargo_context_tests():
    return unittest.suite(
        "cargo_context_tests",
        generated_context_normalization_test,
        workspace_preserves_cargo_settings_test,
        build_script_enters_execution_context_test,
    )
