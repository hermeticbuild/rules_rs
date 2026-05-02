"""Regression tests for musl rustdoc native linking."""

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

def _assert_argv_contains(env, action, expected):
    asserts.true(
        env,
        expected in action.argv,
        "Expected argv to contain {}, got {}".format(expected, action.argv),
    )

def _assert_argv_contains_substrings(env, action, substrings, description):
    for arg in action.argv:
        if all([substring in arg for substring in substrings]):
            return

    asserts.true(
        env,
        False,
        "Expected argv to contain {}, got {}".format(description, action.argv),
    )

def _rustdoc_musl_unwind_link_flags_test_impl(ctx):
    env = analysistest.begin(ctx)
    tut = analysistest.target_under_test(env)
    action = _get_action_by_mnemonic(env, tut, "RustdocTest")

    _assert_argv_contains(env, action, "--test")
    _assert_argv_contains(env, action, "-Clink-arg=-lrustdoc_musl_unwind_cc")
    _assert_argv_contains_substrings(
        env,
        action,
        ["-Clink-arg=-l", "unwind"],
        "a rustdoc-compatible libunwind link argument",
    )

    return analysistest.end(env)

rustdoc_musl_unwind_link_flags_test = analysistest.make(
    _rustdoc_musl_unwind_link_flags_test_impl,
    config_settings = {
        "//command_line_option:extra_execution_platforms": str(Label("//rs/platforms:x86_64-unknown-linux-musl")),
        "//command_line_option:platforms": str(Label("//rs/platforms:x86_64-unknown-linux-musl")),
    },
)
