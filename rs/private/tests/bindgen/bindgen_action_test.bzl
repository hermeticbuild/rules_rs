"""Checks the real bindgen rule with both C++ compiler dialects."""

load("@bazel_skylib//lib:unittest.bzl", "analysistest", "asserts")
load("@rules_cc//cc:action_names.bzl", "ACTION_NAMES")
load("@rules_cc//cc:cc_toolchain_config_lib.bzl", "action_config", "feature", "flag_group", "flag_set", "tool")
load("@rules_cc//cc:defs.bzl", "cc_toolchain")
load("@rules_cc//cc/common:cc_common.bzl", "cc_common")
load("@rules_cc//cc/toolchains:cc_toolchain_config_info.bzl", "CcToolchainConfigInfo")

def _config_impl(ctx):
    is_cl = ctx.attr.compiler == "clang-cl"
    flags = [
        "--target=x86_64-pc-windows-msvc",
        "/imsvc",
        "declared-sdk",
        "/MT",
        "/WX",
        "/clang:-nostdlibinc",
        "/clang:-nobuiltininc",
        "/clang:-fms-compatibility-version=19.50.35717",
        "/clang:-ivfsoverlay",
        "/clang:declared-overlay.json",
    ] if is_cl else ["--target=aarch64-linux-gnu", "-isystem", "declared-sdk"]
    return cc_common.create_cc_toolchain_config_info(
        ctx = ctx,
        toolchain_identifier = ctx.attr.compiler,
        host_system_name = "test",
        target_system_name = "test",
        target_cpu = "test",
        target_libc = "test",
        compiler = ctx.attr.compiler,
        abi_version = "test",
        abi_libc_version = "test",
        cxx_builtin_include_directories = ["/validation-only"],
        action_configs = [action_config(
            action_name = ACTION_NAMES.c_compile,
            tools = [tool(path = "/not-executed/compiler")],
        )],
        features = [
            feature(name = "no_legacy_features"),
            feature(
                name = "compile_flags",
                enabled = True,
                flag_sets = [flag_set(
                    actions = [ACTION_NAMES.c_compile],
                    flag_groups = [
                        flag_group(flags = flags),
                        flag_group(
                            flags = ["/external:I%{system_include_paths}" if is_cl else "-isystem%{system_include_paths}"],
                            iterate_over = "system_include_paths",
                        ),
                        flag_group(flags = ["%{user_compile_flags}"], iterate_over = "user_compile_flags"),
                    ],
                )],
            ),
        ],
    )

_config = rule(
    implementation = _config_impl,
    attrs = {"compiler": attr.string(mandatory = True)},
    provides = [CcToolchainConfigInfo],
)

def _action_test_impl(ctx):
    env = analysistest.begin(ctx)
    actions = analysistest.target_actions(env)
    asserts.equals(env, 1, len(actions))
    action = actions[0]
    asserts.equals(env, "RustBindgen", action.mnemonic)
    argv = action.argv
    for flag in ctx.attr.expected:
        asserts.true(env, flag in argv, "Missing {} in {}".format(flag, argv))
    for flag in ctx.attr.unexpected:
        asserts.false(env, any([flag in arg for arg in argv]), "Unexpected {} in {}".format(flag, argv))
    return analysistest.end(env)

def _action_test(compiler):
    return analysistest.make(
        _action_test_impl,
        attrs = {"expected": attr.string_list(), "unexpected": attr.string_list()},
        config_settings = {
            "//command_line_option:extra_toolchains": [str(Label("//rs/private/tests/bindgen:" + compiler))],
        },
    )

_clang_cl_test = _action_test("clang-cl")
_clang_test = _action_test("clang")

def bindgen_action_tests(name):
    """Tests compiler-based selection independently of target/exec platform OS.

    Args:
      name: Test suite name.
    """
    native.filegroup(name = "empty")
    for compiler in ["clang-cl", "clang"]:
        _config(name = compiler + "_config", compiler = compiler)
        cc_toolchain(
            name = compiler + "_impl",
            toolchain_config = compiler + "_config",
            all_files = "empty",
            ar_files = "empty",
            as_files = "empty",
            compiler_files = "empty",
            dwp_files = "empty",
            linker_files = "empty",
            objcopy_files = "empty",
            strip_files = "empty",
        )
        native.toolchain(
            name = compiler,
            toolchain = compiler + "_impl",
            toolchain_type = "@bazel_tools//tools/cpp:toolchain_type",
        )
    _clang_cl_test(
        name = "clang_cl_action_test",
        target_under_test = "bindings_clang_cl",
        expected = [
            "--driver-mode=cl",
            "--target=x86_64-pc-windows-msvc",
            "/imsvc",
            "declared-sdk",
            "/MT",
            "/WX",
            "/clang:-nostdlibinc",
            "/clang:-nobuiltininc",
            "/std:c++20",
            "/clang:-fms-compatibility-version=19.50.35717",
            "/clang:-ivfsoverlay",
            "/clang:declared-overlay.json",
            "-x",
            "c++",
            "-DFROM_CC_INFO=1",
        ],
        unexpected = ["/validation-only", "-idirafter", "-isystem"],
    )
    _clang_test(
        name = "clang_action_test",
        target_under_test = "bindings",
        expected = ["--target=aarch64-linux-gnu", "-isystem", "declared-sdk", "-isystem/validation-only", "-std=c++20", "-x", "c++", "-DFROM_CC_INFO=1"],
        unexpected = ["--driver-mode=cl", "/clang:", "/imsvc"],
    )
    native.test_suite(name = name, tests = ["clang_cl_action_test", "clang_action_test"])
