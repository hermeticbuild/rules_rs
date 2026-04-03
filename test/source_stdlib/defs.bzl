def _use_source_stdlib_transition_impl(settings, attr):
    return {"//command_line_option:platforms": ["@rules_rs//rs/experimental/platforms:aarch64-apple-darwin_source"]}

_use_source_stdlib_transition = transition(
    implementation = _use_source_stdlib_transition_impl,
    inputs = [],
    outputs = ["//command_line_option:platforms"],
)

def _with_source_stdlib_impl(ctx):
    return [DefaultInfo(files = depset(ctx.files.dep))]

with_source_stdlib = rule(
    implementation = _with_source_stdlib_impl,
    attrs = {
        "dep": attr.label(
            cfg = _use_source_stdlib_transition,
            mandatory = True,
        ),
    },
)
