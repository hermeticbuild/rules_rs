"""Helpers for bootstrapping a Rust stdlib from Bazel-built crate targets."""

load("@rules_rust//rust:toolchain.bzl", "rust_stdlib_filegroup")
load("@rules_rust//rust/private:common.bzl", "rust_common")

_TARGET_PLATFORMS_TRANSITION_OUTPUT = "//command_line_option:platforms"
_SOURCE_PLATFORM_SUFFIX = "_source"

def _use_prebuilt_stdlib_transition_impl(settings, attr):
    return {
        _TARGET_PLATFORMS_TRANSITION_OUTPUT: [
            _to_prebuilt_platform(platform)
            for platform in settings[_TARGET_PLATFORMS_TRANSITION_OUTPUT]
        ],
    }

def _to_prebuilt_platform(platform):
    if platform.endswith(_SOURCE_PLATFORM_SUFFIX):
        return platform[:-len(_SOURCE_PLATFORM_SUFFIX)]
    fail("rust_stdlib_from_deps expects source platform labels ending with `_source`, got %s" % platform)

_use_prebuilt_stdlib_transition = transition(
    implementation = _use_prebuilt_stdlib_transition_impl,
    inputs = [_TARGET_PLATFORMS_TRANSITION_OUTPUT],
    outputs = [_TARGET_PLATFORMS_TRANSITION_OUTPUT],
)

def _collect_transitive_stdlib_outputs_impl(ctx):
    transitive = []

    for root in ctx.attr.roots:
        if rust_common.dep_info not in root:
            fail("%s must provide rust_common.dep_info" % root.label)
        transitive.append(root[rust_common.dep_info].transitive_crate_outputs)

    normalized_files = []
    for file in depset(transitive = transitive).to_list():
        normalized = ctx.actions.declare_file(
            "{name}_files/{path}".format(
                name = ctx.label.name,
                path = file.short_path,
            ),
        )
        ctx.actions.symlink(output = normalized, target_file = file)
        normalized_files.append(normalized)

    return [DefaultInfo(files = depset(normalized_files))]

_collect_transitive_stdlib_outputs = rule(
    implementation = _collect_transitive_stdlib_outputs_impl,
    attrs = {
        "roots": attr.label_list(
            cfg = _use_prebuilt_stdlib_transition,
            doc = "Root crate targets whose transitive crate outputs form the bootstrapped stdlib.",
        ),
    },
)

def rust_stdlib_from_deps(name, roots, visibility = None):
    """Create a rust_stdlib_filegroup from transitive outputs of crate targets.

    The `roots` are transitioned back to the prebuilt stdlib toolchain, so the
    source stdlib can bootstrap from the prebuilt toolchain instead of recursing
    on itself.
    """

    collected_name = name + "_transitive_outputs"

    _collect_transitive_stdlib_outputs(
        name = collected_name,
        roots = roots,
        visibility = ["//visibility:private"],
    )

    rust_stdlib_filegroup(
        name = name,
        srcs = [":" + collected_name],
        visibility = visibility,
    )
