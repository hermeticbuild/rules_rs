"""Analysis test verifying that Linux targets include rust-lld/gcc-ld in action inputs."""

load("@bazel_skylib//lib:unittest.bzl", "analysistest", "asserts")

def _get_action_by_mnemonic(env, tut, mnemonic):
    actions = [action for action in tut.actions if action.mnemonic == mnemonic]
    asserts.equals(
        env,
        1,
        len(actions),
        "Expected exactly one {} action, got {}".format(mnemonic, [action.mnemonic for action in tut.actions]),
    )
    return actions[0]

def _self_contained_linker_inputs_test_impl(ctx):
    env = analysistest.begin(ctx)
    tut = analysistest.target_under_test(env)
    action = _get_action_by_mnemonic(env, tut, "Rustc")

    input_basenames = [f.basename for f in action.inputs.to_list()]
    asserts.true(
        env,
        "rust-lld" in input_basenames,
        "Expected 'rust-lld' in Rustc action inputs for Linux target, but it was missing.",
    )
    return analysistest.end(env)

self_contained_linker_x86_64_test = analysistest.make(
    _self_contained_linker_inputs_test_impl,
    config_settings = {
        "//command_line_option:platforms": str(Label("@rules_rs//rs/platforms:x86_64-unknown-linux-gnu")),
    },
)

self_contained_linker_aarch64_test = analysistest.make(
    _self_contained_linker_inputs_test_impl,
    config_settings = {
        "//command_line_option:platforms": str(Label("@rules_rs//rs/platforms:aarch64-unknown-linux-gnu")),
    },
)
