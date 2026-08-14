"""Analysis tests for custom rules_rs Rust compiler toolchains."""

load("@bazel_skylib//lib:unittest.bzl", "analysistest", "asserts")

def _custom_rustc_toolchain_test_impl(ctx):
    env = analysistest.begin(ctx)
    target = analysistest.target_under_test(env)
    toolchain = target[platform_common.ToolchainInfo]

    asserts.equals(env, "custom-rustc", toolchain.rustc.basename)
    asserts.equals(env, "x86_64-unknown-linux-gnu", toolchain.exec_triple.str)
    asserts.true(env, toolchain.cargo != None, "expected the inherited Cargo binary")
    asserts.true(env, toolchain.rust_doc != None, "expected the inherited rustdoc binary")
    asserts.true(env, toolchain.rustc_lib != None, "expected inherited rustc libraries")

    return analysistest.end(env)

def _custom_rustc_action_test_impl(ctx):
    env = analysistest.begin(ctx)
    rustc_actions = [
        action
        for action in analysistest.target_actions(env)
        if action.mnemonic == "Rustc"
    ]
    asserts.equals(env, 1, len(rustc_actions))
    if rustc_actions:
        expected_rustc = "custom-rustc" if ctx.attr.expect_custom_rustc else "rustc"
        asserts.true(
            env,
            expected_rustc in [file.basename for file in rustc_actions[0].inputs.to_list()],
            "expected %s in the Rust compilation inputs" % expected_rustc,
        )

    return analysistest.end(env)

_LINUX_TARGET_SETTINGS = {
    "//command_line_option:platforms": str(Label("//:rbe")),
    "//command_line_option:extra_execution_platforms": str(Label("//:rbe")),
}

custom_rustc_toolchain_test = analysistest.make(
    _custom_rustc_toolchain_test_impl,
    config_settings = _LINUX_TARGET_SETTINGS,
)

custom_rustc_selected_test = analysistest.make(
    _custom_rustc_action_test_impl,
    attrs = {"expect_custom_rustc": attr.bool(default = True)},
    config_settings = _LINUX_TARGET_SETTINGS | {
        "//command_line_option:extra_toolchains": [
            str(Label("//:custom_rust_linux_x86_64_to_non_bpf_targets_1_96_1")),
        ],
    },
)

custom_rustc_fallback_test = analysistest.make(
    _custom_rustc_action_test_impl,
    attrs = {"expect_custom_rustc": attr.bool(default = False)},
    config_settings = {
        "//command_line_option:platforms": str(Label("//:aarch64-unknown-linux-gnu")),
        "//command_line_option:extra_execution_platforms": str(Label("//:rbe")),
        "//command_line_option:extra_toolchains": [
            str(Label("//:custom_rust_linux_x86_64_to_non_bpf_targets_1_96_1")),
        ],
    },
)
