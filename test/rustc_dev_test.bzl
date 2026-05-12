"""Regression tests for opt-in rustc-dev toolchain selection."""

load("@bazel_skylib//lib:unittest.bzl", "analysistest", "asserts")

def _rustc_action(env):
    actions = [action for action in analysistest.target_under_test(env).actions if action.mnemonic == "Rustc"]
    asserts.equals(env, 1, len(actions), "Expected one Rustc action, got {}".format([action.mnemonic for action in actions]))
    return actions[0]

def _has_rustc_driver_rlib_input(action):
    return any([
        file.basename.startswith("librustc_driver-") and file.extension == "rlib"
        for file in action.inputs.to_list()
    ])

def _rustc_dev_enabled_inputs_test_impl(ctx):
    env = analysistest.begin(ctx)
    asserts.true(
        env,
        _has_rustc_driver_rlib_input(_rustc_action(env)),
        "Expected rustc-dev compiler rlibs in the Rustc action inputs",
    )
    return analysistest.end(env)

def _rustc_dev_disabled_inputs_test_impl(ctx):
    env = analysistest.begin(ctx)
    asserts.false(
        env,
        _has_rustc_driver_rlib_input(_rustc_action(env)),
        "Did not expect rustc-dev compiler rlibs in ordinary nightly Rustc inputs",
    )
    return analysistest.end(env)

rustc_dev_enabled_inputs_test = analysistest.make(
    _rustc_dev_enabled_inputs_test_impl,
    config_settings = {
        str(Label("@rules_rust//rust/toolchain/channel:channel")): "nightly",
        str(Label("@rules_rs//rs/toolchains/rustc_dev:enabled")): "true",
    },
)

rustc_dev_disabled_inputs_test = analysistest.make(
    _rustc_dev_disabled_inputs_test_impl,
    config_settings = {
        str(Label("@rules_rust//rust/toolchain/channel:channel")): "nightly",
    },
)
