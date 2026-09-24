"""Hermetically generates Cargo cfg oracle data from the registered rustc."""

def _cfg_oracle_data_impl(ctx):
    rustc_info = ctx.attr._rustc[DefaultInfo]
    rustc_files = rustc_info.files.to_list()
    if len(rustc_files) != 1:
        fail("expected exactly one rustc executable, got {}".format(rustc_files))

    output = ctx.outputs.output
    args = ctx.actions.args()
    args.add("--rustc", rustc_files[0])
    args.add("--output", output)
    args.add_all(ctx.attr.triples, before_each = "--triple")

    ctx.actions.run(
        arguments = [args],
        executable = ctx.executable._generator,
        mnemonic = "GenerateCargoCfgOracle",
        outputs = [output],
        progress_message = "Generating Cargo cfg oracle data for %{label}",
        tools = [depset(transitive = [rustc_info.files, rustc_info.default_runfiles.files])],
    )

    return [DefaultInfo(files = depset([output]))]

cfg_oracle_data = rule(
    implementation = _cfg_oracle_data_impl,
    attrs = {
        "triples": attr.string_list(mandatory = True),
        "_generator": attr.label(
            cfg = "exec",
            default = Label("//tools/cfg_oracle:cfg_oracle_generator"),
            executable = True,
        ),
        "_rustc": attr.label(
            cfg = "exec",
            default = Label("@rules_rust//rust/toolchain:current_rustc_files"),
        ),
    },
    outputs = {
        "output": "%{name}.bzl",
    },
)
