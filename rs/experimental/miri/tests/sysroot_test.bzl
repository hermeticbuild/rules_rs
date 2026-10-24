"""Analysis tests for Miri sysroots."""

load("@bazel_skylib//lib:unittest.bzl", "analysistest", "asserts")
load("//rs/experimental/miri/private:providers.bzl", "MiriSysrootInfo")

_EXTRA_TOOLCHAINS = "//command_line_option:extra_toolchains"

def _invalid_triple_toolchain_impl(_ctx):
    return [platform_common.ToolchainInfo(target_triple = 42)]

invalid_triple_toolchain = rule(implementation = _invalid_triple_toolchain_impl)

def _invalid_target_triple_test_impl(ctx):
    env = analysistest.begin(ctx)
    asserts.expect_failure(env, "Miri sysroot toolchain must provide a string target_triple")
    return analysistest.end(env)

invalid_target_triple_test = analysistest.make(
    _invalid_target_triple_test_impl,
    config_settings = {_EXTRA_TOOLCHAINS: [str(Label(":invalid_triple_toolchain"))]},
    expect_failure = True,
)

def _valid_target_triple_test_impl(ctx):
    env = analysistest.begin(ctx)
    asserts.equals(env, ctx.attr.expected_triple, analysistest.target_under_test(env)[MiriSysrootInfo].target_triple)
    return analysistest.end(env)

valid_target_triple_test = analysistest.make(
    _valid_target_triple_test_impl,
    attrs = {"expected_triple": attr.string(mandatory = True)},
    config_settings = {_EXTRA_TOOLCHAINS: [str(Label(":valid_triple_toolchain"))]},
)
