"""Regression tests for target-only optional build dependencies.

Long Ho's reproduction: https://github.com/longlho/rules-rs-optional-build-dep-repro
"""

load("@bazel_skylib//lib:unittest.bzl", "analysistest", "asserts")

_BuildScriptActionsInfo = provider(fields = ["arguments_by_output"])

def _build_script_actions_impl(target, ctx):
    arguments_by_output = {}
    for attr_name in ["deps", "script"]:
        deps = getattr(ctx.rule.attr, attr_name, [])
        if type(deps) != "list":
            deps = [deps]
        for dep in deps:
            if _BuildScriptActionsInfo in dep:
                arguments_by_output.update(dep[_BuildScriptActionsInfo].arguments_by_output)

    for action in target.actions:
        if action.mnemonic != "Rustc":
            continue
        arguments = action.argv
        if not any([arg.endswith("/build.rs") and "libdbus-sys" in arg for arg in arguments]):
            continue
        arguments_by_output[action.outputs.to_list()[0].path] = arguments

    return [_BuildScriptActionsInfo(arguments_by_output = arguments_by_output)]

_build_script_actions = aspect(
    implementation = _build_script_actions_impl,
    attr_aspects = ["deps", "script"],
)

def _optional_target_build_dep_test_impl(ctx):
    env = analysistest.begin(ctx)
    target = analysistest.target_under_test(env)
    actions = target[_BuildScriptActionsInfo].arguments_by_output
    if ctx.attr.vendored:
        actions = {output: arguments for output, arguments in actions.items() if 'feature="vendored"' in arguments}
    asserts.true(env, bool(actions), "Expected a libdbus-sys build-script compiler action")

    for output, arguments in actions.items():
        asserts.equals(env, ctx.attr.vendored, 'feature="vendored"' in arguments, "Unexpected vendored feature in " + output)
        asserts.equals(env, ctx.attr.vendored, 'feature="cc"' in arguments, "Unexpected cc feature in " + output)
        asserts.equals(
            env,
            ctx.attr.vendored,
            any([arg.startswith("--extern=cc=") for arg in arguments]),
            "Only the vendored build script should receive cc on %s: %s" % (ctx.attr.exec_triple, output),
        )
        asserts.true(
            env,
            ctx.attr.exec_triple in arguments or "--target=" + ctx.attr.exec_triple in arguments,
            "Expected the build script to compile for %s: %s" % (ctx.attr.exec_triple, output),
        )

    return analysistest.end(env)

def _make_optional_target_build_dep_test(
        exec_platform,
        exec_triple,
        target_platform = Label("//:x86_64-unknown-linux-gnu"),
        vendored = True):
    return analysistest.make(
        _optional_target_build_dep_test_impl,
        attrs = {
            "exec_triple": attr.string(default = exec_triple),
            "vendored": attr.bool(default = vendored),
        },
        config_settings = {
            "//command_line_option:extra_execution_platforms": str(exec_platform),
            "//command_line_option:host_platform": str(exec_platform),
            "//command_line_option:platforms": str(target_platform),
        },
        extra_target_under_test_aspects = [_build_script_actions],
    )

optional_target_build_dep_macos_test = _make_optional_target_build_dep_test(
    Label("@rules_rs//rs/platforms:aarch64-apple-darwin"),
    "aarch64-apple-darwin",
)

optional_target_build_dep_linux_test = _make_optional_target_build_dep_test(
    Label("//:x86_64-unknown-linux-gnu"),
    "x86_64-unknown-linux-gnu",
)

optional_target_build_dep_macos_target_test = _make_optional_target_build_dep_test(
    Label("@rules_rs//rs/platforms:aarch64-apple-darwin"),
    "aarch64-apple-darwin",
    target_platform = Label("@rules_rs//rs/platforms:aarch64-apple-darwin"),
    vendored = False,
)
