load("@rules_rust//rust:defs.bzl", "rust_stdlib_filegroup")
load("@rules_rust//rust:rust_common.bzl", "CrateInfo", "DepInfo")

def _source_stdlib_build_transition_impl(_settings, _attr):
    return {
        "@rules_rust//rust/private:bootstrap_setting": False,
        "//rs/private:source_stdlib_building": True,
    }

_source_stdlib_build_transition = transition(
    implementation = _source_stdlib_build_transition_impl,
    inputs = [],
    outputs = [
        "@rules_rust//rust/private:bootstrap_setting",
        "//rs/private:source_stdlib_building",
    ],
)

def _source_stdlib_artifacts_impl(ctx):
    srcs = {}
    for crate in ctx.attr.crates:
        if CrateInfo in crate:
            output = crate[CrateInfo].output
            if output:
                srcs[output.short_path] = output
        if DepInfo in crate:
            for output in crate[DepInfo].transitive_crate_outputs.to_list():
                srcs[output.short_path] = output

    outputs = {}
    for path in sorted(srcs.keys()):
        src = srcs[path]
        if src.basename in outputs:
            fail("source stdlib output path collision: {}".format(src.basename))
        out = ctx.actions.declare_file("{}/{}".format(ctx.label.name, src.basename))
        ctx.actions.symlink(output = out, target_file = src)
        outputs[src.basename] = out

    return DefaultInfo(files = depset([outputs[path] for path in sorted(outputs.keys())]))

source_stdlib_artifacts = rule(
    implementation = _source_stdlib_artifacts_impl,
    attrs = {
        "crates": attr.label_list(
            cfg = _source_stdlib_build_transition,
            providers = [CrateInfo],
            mandatory = True,
        ),
        "_allowlist_function_transition": attr.label(
            default = Label("@bazel_tools//tools/allowlists/function_transition_allowlist"),
        ),
    },
)

def source_stdlib(*, name, crates):
    source_stdlib_artifacts(
        name = name + "_artifacts",
        crates = crates,
    )

    rust_stdlib_filegroup(
        name = name,
        srcs = [name + "_artifacts"],
        visibility = ["//visibility:public"],
    )
