"""Regression coverage for https://github.com/hermeticbuild/rules_rs/issues/277."""

load("@bazel_skylib//lib:unittest.bzl", "analysistest", "asserts")
load("@rules_rust//rust:rust_common.bzl", "CrateInfo")

# buildifier: disable=bzl-visibility
load("@rules_rust//rust/private:rust_analyzer.bzl", "rust_analyzer_aspect")

_SETTING = str(Label("@rules_rust//cargo/settings:cargo_target_triple"))
_WINDOWS = "x86_64-pc-windows-gnullvm"
_LINUX = "aarch64-unknown-linux-gnu"

def _prost_impl(ctx):
    env = analysistest.begin(ctx)
    asserts.true(env, platform_common.ToolchainInfo in analysistest.target_under_test(env))
    return analysistest.end(env)

def _consumer_impl(ctx):
    env = analysistest.begin(ctx)
    crate = analysistest.target_under_test(env)[CrateInfo]
    asserts.equals(env, "consumer.rs", crate.root.basename)
    rustc_args = [arg for action in analysistest.target_actions(env) for arg in (action.argv or [])]
    asserts.true(env, any([arg.startswith("--extern=renamed_macro=") for arg in rustc_args]), str(rustc_args))
    dylibs = analysistest.target_under_test(env)[OutputGroupInfo].rust_analyzer_proc_macro_dylib.to_list()
    asserts.true(env, len(dylibs) > 0)
    asserts.false(env, any(["__cargo_unresolved" in file.owner.name for file in dylibs]), str(dylibs))
    return analysistest.end(env)

def _inactive_impl(ctx):
    env = analysistest.begin(ctx)
    crate = analysistest.target_under_test(env)[CrateInfo]
    asserts.equals(env, "lib.rs", crate.root.basename)
    asserts.equals(env, "target_only__cargo_active", crate.owner.name)
    asserts.equals(env, [], crate.deps.to_list())
    asserts.equals(env, {}, crate.rustc_env)
    asserts.equals(env, [], crate.rustc_env_files)
    asserts.true(env, crate.output in crate.compile_data.to_list())
    return analysistest.end(env)

def _inactive_macro_impl(ctx):
    env = analysistest.begin(ctx)
    target = analysistest.target_under_test(env)
    asserts.equals(env, "proc-macro", target[CrateInfo].type)
    asserts.equals(env, "generated_macro__cargo_active", target[CrateInfo].owner.name)
    asserts.equals(env, [], analysistest.target_actions(env))
    asserts.equals(env, [], target[OutputGroupInfo].rust_analyzer_proc_macro_dylib.to_list())
    return analysistest.end(env)

_inactive_macro_test = analysistest.make(_inactive_macro_impl, extra_target_under_test_aspects = [rust_analyzer_aspect], config_settings = {
    "//command_line_option:platforms": str(Label("//rs/platforms:x86_64-unknown-linux-musl")),
    _SETTING: _WINDOWS,
})

_prost_windows_test = analysistest.make(_prost_impl, config_settings = {
    "//command_line_option:platforms": str(Label("//rs/platforms:" + _WINDOWS)),
    _SETTING: _WINDOWS,
})
_prost_linux_test = analysistest.make(_prost_impl, config_settings = {
    "//command_line_option:platforms": str(Label("//rs/platforms:" + _LINUX)),
    _SETTING: _LINUX,
})
_consumer_test = analysistest.make(_consumer_impl, extra_target_under_test_aspects = [rust_analyzer_aspect], config_settings = {
    "//command_line_option:platforms": str(Label("//rs/platforms:" + _WINDOWS)),
    _SETTING: "",
})
_inactive_test = analysistest.make(_inactive_impl, config_settings = {
    "//command_line_option:platforms": str(Label("//rs/platforms:" + _LINUX)),
    _SETTING: "",
})

def rendered_tests():
    _inactive_macro_test(name = "inactive_macro_editor_test", target_under_test = "@feature_context_rendered//:generated_macro")
    _prost_windows_test(name = "prost_windows_context_test", target_under_test = "//rs/private/prost:default_prost_toolchain_impl")
    _prost_linux_test(name = "prost_linux_context_test", target_under_test = "//rs/private/prost:default_prost_toolchain_impl")
    _consumer_test(name = "rendered_context_test", target_under_test = "@feature_context_rendered//:consumer")
    _inactive_test(name = "inactive_context_test", target_under_test = "@feature_context_rendered//:target_only")
