"""Testcase to verify opt_level is correctly passed"""

def _opt_level_info_impl(ctx):
    toolchain = ctx.toolchains["@rules_rust//rust:toolchain_type"]
    opt_mode = toolchain.compilation_mode_opts.get("opt")
    value = opt_mode.opt_level if opt_mode else "(unset)"

    out = ctx.actions.declare_file(ctx.label.name + ".txt")
    ctx.actions.write(out, "opt_level[opt] = " + value + "\n")
    return [DefaultInfo(files = depset([out]))]

opt_level_info = rule(
    implementation = _opt_level_info_impl,
    toolchains = ["@rules_rust//rust:toolchain_type"],
)
