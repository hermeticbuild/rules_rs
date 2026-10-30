"""Build resolved workspace dependencies in their Cargo compilation contexts."""

load(":cargo_select.bzl", "cargo_select")

_SETTING = str(Label("@rules_rust//cargo/settings:cargo_target_triple"))

def _cargo_target_impl(_settings, attr):
    return {_SETTING: attr.cargo_target_triple}

_cargo_target = transition(
    implementation = _cargo_target_impl,
    inputs = [],
    outputs = [_SETTING],
)

def _exec_deps_impl(ctx):
    actual = ctx.attr.actual[DefaultInfo]
    return [DefaultInfo(
        files = actual.files,
        default_runfiles = actual.default_runfiles,
        data_runfiles = actual.data_runfiles,
    )]

_exec_deps = rule(
    implementation = _exec_deps_impl,
    attrs = {
        "actual": attr.label(mandatory = True, cfg = "exec"),
        "cargo_target_triple": attr.string(mandatory = True),
        "_allowlist_function_transition": attr.label(default = "@bazel_tools//tools/allowlists/function_transition_allowlist"),
    },
    cfg = _cargo_target,
    toolchains = ["@rules_rust//rust:toolchain_type"],
)

def cargo_workspace_deps(name, target_deps, exec_deps, use_legacy_rules_rust_platforms = False):
    """Aggregate dependencies without changing their compilation domains.

    Args:
        name: Name of the combined filegroup.
        target_deps: Version-qualified dependency labels by target triple.
        exec_deps: Dependency labels by original target triple and execution triple.
        use_legacy_rules_rust_platforms: Select the standard compiler's platform labels.
    """
    execution = {}
    for target_triple, by_host in exec_deps.items():
        execution[target_triple] = []
        if not any(by_host.values()):
            continue
        host_group = name + "__host_" + target_triple
        wrapper = name + "__exec_" + target_triple

        # Select the wrapper on the target platform, preserve that Cargo context,
        # then select the actual dependencies after the execution transition.
        native.filegroup(
            name = host_group,
            srcs = cargo_select({"": by_host}, "", use_legacy_rules_rust_platforms, default = []),
            tags = ["manual"],
            visibility = ["//visibility:private"],
        )
        _exec_deps(
            name = wrapper,
            actual = ":" + host_group,
            cargo_target_triple = target_triple,
            tags = ["manual"],
            visibility = ["//visibility:private"],
        )
        execution[target_triple] = [":" + wrapper]
    native.filegroup(
        name = name,
        srcs = cargo_select({"": target_deps}, "", use_legacy_rules_rust_platforms, default = []) + cargo_select({"": execution}, "", use_legacy_rules_rust_platforms, default = []),
    )
