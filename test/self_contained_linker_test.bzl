"""Analysis test verifying that Linux x86_64 targets disable self-contained LLD via -Clinker-features=-lld."""

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

def _self_contained_linker_x86_64_test_impl(ctx):
    env = analysistest.begin(ctx)
    tut = analysistest.target_under_test(env)
    action = _get_action_by_mnemonic(env, tut, "Rustc")

    asserts.true(
        env,
        "-Clinker-features=-lld" in action.argv,
        "Expected '-Clinker-features=-lld' in Rustc action argv for x86_64-unknown-linux-gnu, but it was missing: {}".format(action.argv),
    )
    return analysistest.end(env)

def _self_contained_linker_aarch64_test_impl(ctx):
    env = analysistest.begin(ctx)
    tut = analysistest.target_under_test(env)
    action = _get_action_by_mnemonic(env, tut, "Rustc")

    asserts.false(
        env,
        "-Clinker-features=-lld" in action.argv,
        "Did not expect '-Clinker-features=-lld' in Rustc action argv for aarch64-unknown-linux-gnu: {}".format(action.argv),
    )
    return analysistest.end(env)

self_contained_linker_x86_64_test = analysistest.make(
    _self_contained_linker_x86_64_test_impl,
    config_settings = {
        "//command_line_option:platforms": str(Label("@rules_rs//rs/platforms:x86_64-unknown-linux-gnu")),
    },
)

self_contained_linker_aarch64_test = analysistest.make(
    _self_contained_linker_aarch64_test_impl,
    config_settings = {
        "//command_line_option:platforms": str(Label("@rules_rs//rs/platforms:aarch64-unknown-linux-gnu")),
    },
)
