"""Checks the compiler selected by generated and custom toolchains."""

load("@bazel_skylib//lib:unittest.bzl", "analysistest", "asserts")

def _toolchain_version_test_impl(ctx):
    env = analysistest.begin(ctx)
    target = analysistest.target_under_test(env)
    rustc = target[platform_common.ToolchainInfo].rustc
    actions = [action for action in target.actions if rustc in action.outputs.to_list()]
    asserts.equals(env, 1, len(actions))
    if actions:
        asserts.true(env, ctx.file.expected_rustc in actions[0].inputs.to_list())
    return analysistest.end(env)

toolchain_version_test = analysistest.make(
    _toolchain_version_test_impl,
    attrs = {
        "expected_rustc": attr.label(allow_single_file = True, mandatory = True),
    },
)
