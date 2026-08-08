"""Analysis tests for generated Cargo workspace lint configuration."""

load("@bazel_skylib//lib:unittest.bzl", "analysistest", "asserts")

def _rustc_action(env, target):
    actions = [action for action in target.actions if action.mnemonic == "Rustc"]
    asserts.equals(
        env,
        1,
        len(actions),
        "Expected exactly one Rustc action, got {}".format(
            [action.mnemonic for action in target.actions],
        ),
    )
    return actions[0]

def _explicit_workspace_lints_test_impl(ctx):
    env = analysistest.begin(ctx)
    target = analysistest.target_under_test(env)
    action = _rustc_action(env, target)

    asserts.true(
        env,
        "--deny=unused_imports" in action.argv,
        "Expected workspace lint flag in {}".format(action.argv),
    )

    return analysistest.end(env)

explicit_workspace_lints_test = analysistest.make(
    _explicit_workspace_lints_test_impl,
)

def _manifest_only_workspace_lints_test_impl(ctx):
    env = analysistest.begin(ctx)
    target = analysistest.target_under_test(env)
    action = _rustc_action(env, target)

    asserts.false(
        env,
        "--deny=unused_imports" in action.argv,
        "Cargo workspace inheritance unexpectedly configured {}".format(
            action.argv,
        ),
    )

    return analysistest.end(env)

manifest_only_workspace_lints_test = analysistest.make(
    _manifest_only_workspace_lints_test_impl,
)

def _opted_out_workspace_lints_test_impl(ctx):
    env = analysistest.begin(ctx)
    target = analysistest.target_under_test(env)
    action = _rustc_action(env, target)

    asserts.false(
        env,
        "--deny=unused_imports" in action.argv,
        "Opted-out target unexpectedly received workspace lints: {}".format(
            action.argv,
        ),
    )

    return analysistest.end(env)

opted_out_workspace_lints_test = analysistest.make(
    _opted_out_workspace_lints_test_impl,
)
