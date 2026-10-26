"""Analysis tests for workspace-declared Rust toolchains."""

load("@bazel_skylib//lib:unittest.bzl", "analysistest", "asserts")
load("//rs/toolchains:declare_rustc_toolchains.bzl", "declare_rustc_toolchains")

_RUST_TOOLCHAIN = "@rules_rust//rust:toolchain_type"
_CARGO_TOOLCHAIN = "@rules_rust//cargo:toolchain_type"
_PLATFORM = "//command_line_option:platforms"
_BOOTSTRAP = str(Label("@rules_rust//rust/private:bootstrap_setting"))
_SOURCE_STDLIB = str(Label("//rs/private:source_stdlib_building"))
_PACKAGE = "//rs/toolchains/tests:"

_ResolvedToolchains = provider(fields = ["rust", "cargo"])

def _resolved_toolchain_impl(ctx):
    return [_ResolvedToolchains(
        rust = ctx.toolchains[_RUST_TOOLCHAIN],
        cargo = ctx.toolchains[_CARGO_TOOLCHAIN],
    )]

_resolved_toolchain = rule(
    implementation = _resolved_toolchain_impl,
    toolchains = [_RUST_TOOLCHAIN, _CARGO_TOOLCHAIN],
)

def _selection_test_impl(ctx):
    env = analysistest.begin(ctx)
    resolved = analysistest.target_under_test(env)[_ResolvedToolchains]
    toolchain = resolved.rust
    asserts.equals(env, ctx.attr.expected_triple, toolchain.target_triple.str)
    asserts.equals(env, ctx.attr.expected_exec_triple, toolchain.exec_triple.str)
    asserts.equals(env, ctx.attr.expected_edition, toolchain.default_edition)
    asserts.equals(env, ctx.attr.expected_bootstrap, toolchain._bootstrapping)
    asserts.equals(env, ctx.attr.expected_linker_preference, toolchain.linker_preference or "")
    asserts.equals(env, ctx.attr.expected_linker, toolchain.linker.basename if toolchain.linker else "")
    asserts.equals(env, ctx.attr.expected_dlltool, toolchain.dlltool.basename if toolchain.dlltool else "")
    asserts.equals(env, None, toolchain.cargo)
    asserts.equals(env, ctx.attr.expected_cargo, resolved.cargo.cargo.basename)
    if ctx.attr.expected_cargo == "custom-cargo":
        asserts.true(env, "custom-cargo-version" in [f.basename for f in resolved.cargo.all_files.to_list()])
    for tc in [toolchain, resolved.cargo]:
        asserts.equals(env, "1.92.0", tc.version)
        asserts.equals(env, "stable", tc.channel)
        asserts.equals(env, "", tc.iso_date)
    return analysistest.end(env)

def _selection_test(triple, bootstrap = False, exec_triple = "x86_64-unknown-linux-gnu"):
    return analysistest.make(
        _selection_test_impl,
        attrs = {
            "expected_triple": attr.string(default = triple),
            "expected_exec_triple": attr.string(default = exec_triple),
            "expected_edition": attr.string(default = "2024"),
            "expected_bootstrap": attr.bool(default = bootstrap),
            "expected_linker": attr.string(),
            "expected_dlltool": attr.string(),
            "expected_linker_preference": attr.string(),
            "expected_cargo": attr.string(default = "custom-cargo"),
        },
        config_settings = {
            _PLATFORM: str(Label("//rs/platforms:" + triple)),
            _BOOTSTRAP: bootstrap,
            # Analyze BPF toolchain selection without building its source stdlib.
            _SOURCE_STDLIB: True,
            "//command_line_option:extra_execution_platforms": [str(Label("//rs/platforms:" + exec_triple))],
            "//command_line_option:extra_toolchains": [
                str(Label(_PACKAGE + "narrow_linux_x86_64_1_92_0_cargo")),
                str(Label(_PACKAGE + "narrow_linux_x86_64_to_non_bpf_targets_1_92_0")),
                str(Label(_PACKAGE + "narrow_linux_x86_64_to_non_bpf_targets_1_92_0_bootstrap")),
                str(Label(_PACKAGE + "narrow_linux_x86_64_to_bpf_targets_1_92_0")),
            ],
        },
    )

_musl_test = _selection_test("x86_64-unknown-linux-musl")
_aarch64_musl_test = _selection_test("aarch64-unknown-linux-musl")
_aarch64_exec_test = _selection_test("aarch64-unknown-linux-musl", exec_triple = "aarch64-unknown-linux-gnu")
_gnu_test = _selection_test("x86_64-unknown-linux-gnu")
_musl_bootstrap_test = _selection_test("x86_64-unknown-linux-musl", bootstrap = True)
_gnu_bootstrap_test = _selection_test("x86_64-unknown-linux-gnu", bootstrap = True)
_bpfel_test = _selection_test("bpfel-unknown-none")
_bpfeb_test = _selection_test("bpfeb-unknown-none")
_thumbv6m_test = _selection_test("thumbv6m-none-eabi")
_riscv32imac_test = _selection_test("riscv32imac-unknown-none-elf")
_x86_64_none_test = _selection_test("x86_64-unknown-none")
_windows_gnu_test = _selection_test("x86_64-pc-windows-gnu")
_windows_gnullvm_test = _selection_test("x86_64-pc-windows-gnullvm")
_windows_msvc_test = _selection_test("x86_64-pc-windows-msvc")

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
        cargo = {"x86_64-unknown-linux-gnu": ":custom_cargo"},
        exec_triples = ["x86_64-unknown-linux-gnu"],
        target_triples = [
            "x86_64-unknown-linux-musl",
            "aarch64-unknown-linux-musl",
            "bpfel-unknown-none",
            "thumbv6m-none-eabi",
            "riscv32imac-unknown-none-elf",
            "x86_64-unknown-none",
            "x86_64-pc-windows-gnu",
            "x86_64-pc-windows-gnullvm",
            "x86_64-pc-windows-msvc",
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
        ("aarch64_exec_fallback", _aarch64_exec_test, {"expected_edition": "2021", "expected_cargo": "cargo"}),
        ("gnu_fallback", _gnu_test, {"expected_edition": "2021", "expected_cargo": "cargo"}),
        ("musl_bootstrap", _musl_bootstrap_test, {}),
        ("gnu_bootstrap_fallback", _gnu_bootstrap_test, {"expected_edition": "2021", "expected_cargo": "cargo"}),
        ("bpfel", _bpfel_test, {"expected_linker": "bpf-linker", "expected_linker_preference": "rust"}),
        ("bpfeb_fallback", _bpfeb_test, {"expected_edition": "2021", "expected_cargo": "cargo", "expected_linker": "bpf-linker", "expected_linker_preference": "rust"}),
        ("thumbv6m", _thumbv6m_test, {"expected_linker": "rust-lld"}),
        ("riscv32imac", _riscv32imac_test, {"expected_linker": "rust-lld"}),
        ("x86_64_none", _x86_64_none_test, {"expected_linker": "rust-lld"}),
        ("windows_gnu", _windows_gnu_test, {"expected_dlltool": "llvm-dlltool"}),
        ("windows_gnullvm", _windows_gnullvm_test, {}),
        ("windows_msvc", _windows_msvc_test, {}),
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
