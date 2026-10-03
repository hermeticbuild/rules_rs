"""Analysis tests for workspace-declared Rust toolchains."""

load("@bazel_skylib//lib:unittest.bzl", "analysistest", "asserts")
load("//rs/toolchains:declare_rustc_toolchains.bzl", "declare_rustc_toolchains")

_RUST_TOOLCHAIN = "@rules_rust//rust:toolchain_type"
_PLATFORM = "//command_line_option:platforms"
_BOOTSTRAP = str(Label("@rules_rust//rust/private:bootstrap_setting"))
_SOURCE_STDLIB = str(Label("//rs/private:source_stdlib_building"))
_PACKAGE = "//rs/toolchains/tests:"

def _resolved_toolchain_impl(ctx):
    return [ctx.toolchains[_RUST_TOOLCHAIN]]

_resolved_toolchain = rule(
    implementation = _resolved_toolchain_impl,
    toolchains = [_RUST_TOOLCHAIN],
)

def _selection_test_impl(ctx):
    env = analysistest.begin(ctx)
    toolchain = analysistest.target_under_test(env)[platform_common.ToolchainInfo]
    asserts.equals(env, ctx.attr.expected_triple, toolchain.target_triple.str)
    asserts.equals(env, ctx.attr.expected_edition, toolchain.default_edition)
    asserts.equals(env, ctx.attr.expected_bootstrap, toolchain._bootstrapping)
    asserts.equals(env, ctx.attr.expected_linker_preference, toolchain.linker_preference or "")
    return analysistest.end(env)

def _selection_test(triple, bootstrap = False):
    return analysistest.make(
        _selection_test_impl,
        attrs = {
            "expected_triple": attr.string(default = triple),
            "expected_edition": attr.string(default = "2024"),
            "expected_bootstrap": attr.bool(default = bootstrap),
            "expected_linker_preference": attr.string(),
        },
        config_settings = {
            _PLATFORM: str(Label("//rs/platforms:" + triple)),
            _BOOTSTRAP: bootstrap,
            # Analyze BPF toolchain selection without building its source stdlib.
            _SOURCE_STDLIB: True,
            "//command_line_option:extra_execution_platforms": [str(Label("//rs/platforms:x86_64-unknown-linux-gnu"))],
            "//command_line_option:extra_toolchains": [
                str(Label(_PACKAGE + "narrow_linux_x86_64_to_non_bpf_targets_1_92_0")),
                str(Label(_PACKAGE + "narrow_linux_x86_64_to_non_bpf_targets_1_92_0_bootstrap")),
                str(Label(_PACKAGE + "narrow_linux_x86_64_to_bpf_targets_1_92_0")),
            ],
        },
    )

_musl_test = _selection_test("x86_64-unknown-linux-musl")
_aarch64_musl_test = _selection_test("aarch64-unknown-linux-musl")
_gnu_test = _selection_test("x86_64-unknown-linux-gnu")
_musl_bootstrap_test = _selection_test("x86_64-unknown-linux-musl", bootstrap = True)
_gnu_bootstrap_test = _selection_test("x86_64-unknown-linux-gnu", bootstrap = True)
_bpfel_test = _selection_test("bpfel-unknown-none")
_bpfeb_test = _selection_test("bpfeb-unknown-none")

def _analyze_declarations_impl(_ctx):
    return []

_analyze_declarations = rule(
    implementation = _analyze_declarations_impl,
    attrs = {"targets": attr.label_list()},
)

def _unsupported_platform_test_impl(ctx):
    env = analysistest.begin(ctx)
    return analysistest.end(env)

_unsupported_platform_test = analysistest.make(
    _unsupported_platform_test_impl,
    config_settings = {_PLATFORM: str(Label("//rs/platforms:x86_64-unknown-linux-gnu"))},
)

def declare_rustc_toolchains_test_suite(name):
    """Checks target-triple restrictions and analysis on unsupported platforms.

    Args:
        name: Test suite name.
    """
    declare_rustc_toolchains(
        name = "narrow",
        version = "1.92.0",
        edition = "2024",
        exec_triples = ["x86_64-unknown-linux-gnu"],
        target_triples = [
            "x86_64-unknown-linux-musl",
            "aarch64-unknown-linux-musl",
            "bpfel-unknown-none",
        ],
    )
    declare_rustc_toolchains(
        name = "source_only",
        version = "1.92.0",
        exec_triples = ["x86_64-unknown-linux-gnu"],
        target_triples = ["bpfeb-unknown-none"],
    )
    _analyze_declarations(
        name = "analyze_declarations",
        targets = [":" + target for target in native.existing_rules()],
        tags = ["manual"],
    )
    _resolved_toolchain(name = "resolved_toolchain", tags = ["manual"])

    tests = []
    for test_name, test_rule, kwargs in [
        ("musl", _musl_test, {}),
        ("aarch64_musl", _aarch64_musl_test, {}),
        ("gnu_fallback", _gnu_test, {"expected_edition": "2021"}),
        ("musl_bootstrap", _musl_bootstrap_test, {}),
        ("gnu_bootstrap_fallback", _gnu_bootstrap_test, {"expected_edition": "2021"}),
        ("bpfel", _bpfel_test, {"expected_linker_preference": "rust"}),
        ("bpfeb_fallback", _bpfeb_test, {"expected_edition": "2021", "expected_linker_preference": "rust"}),
    ]:
        test_rule(
            name = test_name + "_test",
            target_under_test = ":resolved_toolchain",
            **kwargs
        )
        tests.append(":" + test_name + "_test")

    _unsupported_platform_test(
        name = "unsupported_platform_test",
        target_under_test = ":analyze_declarations",
    )
    tests.append(":unsupported_platform_test")
    native.test_suite(name = name, tests = tests)
