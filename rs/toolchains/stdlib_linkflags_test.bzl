"""Checks that standard-library link flags follow the resolved Rust target."""

load("@bazel_skylib//lib:unittest.bzl", "asserts", "unittest")

_WINDOWS_GNU_FLAGS = ["-lws2_32", "-luserenv", "-lbcrypt", "-lntdll", "-lsynchronization"]
_CASES = {
    "linux_with_msvc_abi": ("x86_64-unknown-linux-gnu", "msvc", []),
    "macos_with_gnu_abi": ("aarch64-apple-darwin", "gnu", ["-lSystem", "-lresolv"]),
    "windows_msvc": ("aarch64-pc-windows-msvc", None, ["advapi32.lib", "ws2_32.lib", "userenv.lib", "Bcrypt.lib"]),
    "windows_gnu": ("x86_64-pc-windows-gnu", None, _WINDOWS_GNU_FLAGS),
    "windows_gnullvm": ("aarch64-pc-windows-gnullvm", None, _WINDOWS_GNU_FLAGS),
}

_StdlibInfo = provider(
    "Resolved Rust target and standard-library link flags.",
    fields = {
        "triple": "Resolved Rust target triple.",
        "flags": "Native linker flags required by the Rust standard library.",
    },
)

def _stdlib_info_impl(ctx):
    toolchain = ctx.toolchains["@rules_rust//rust:toolchain_type"]
    return [_StdlibInfo(
        triple = toolchain.target_triple.str,
        flags = [
            flag
            for linker_input in toolchain.stdlib_linkflags.linking_context.linker_inputs.to_list()
            for flag in linker_input.user_link_flags
        ],
    )]

_stdlib_info = rule(
    implementation = _stdlib_info_impl,
    toolchains = ["@rules_rust//rust:toolchain_type"],
)

def _target_platforms_impl(_settings, _attr):
    return {
        name: {"//command_line_option:platforms": [str(Label("//rs/toolchains:stdlib_" + name))]}
        for name in _CASES
    }

_target_platforms = transition(
    implementation = _target_platforms_impl,
    inputs = [],
    outputs = ["//command_line_option:platforms"],
)

def _stdlib_linkflags_test_impl(ctx):
    env = unittest.begin(ctx)
    for name, (triple, _, flags) in _CASES.items():
        actual = ctx.split_attr.target[name][_StdlibInfo]
        asserts.equals(env, triple, actual.triple, name)
        asserts.equals(env, flags, actual.flags, name)
    return unittest.end(env)

_stdlib_linkflags_test = unittest.make(
    _stdlib_linkflags_test_impl,
    attrs = {
        "target": attr.label(cfg = _target_platforms, mandatory = True),
        "_allowlist_function_transition": attr.label(
            default = "@bazel_tools//tools/allowlists/function_transition_allowlist",
        ),
    },
)

def stdlib_linkflags_test(name):
    for case, (triple, extra_abi, _) in _CASES.items():
        # ABI constraints are independent of the OS. They must not introduce
        # Windows libraries or ambiguous selects on a non-Windows Rust target.
        native.platform(
            name = "stdlib_" + case,
            parents = ["@rules_rs//rs/platforms:" + triple],
            constraint_values = ["@llvm//constraints/windows/abi:" + extra_abi] if extra_abi else [],
        )

    _stdlib_info(name = "stdlib_info", tags = ["manual"])
    _stdlib_linkflags_test(name = name, target = ":stdlib_info")
