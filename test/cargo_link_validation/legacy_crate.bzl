"""A custom CrateInfo producer that predates crate_identity.

It constructs CrateInfo without a `crate_identity`; `create_crate_info` treats
that as an absent logical identity, so custom producers remain compatible."""

load("@rules_rust//rust:rust_common.bzl", "rust_common")

def _legacy_crate_impl(ctx):
    crate = ctx.attr.crate[rust_common.crate_info]
    legacy = rust_common.crate_info(
        aliases = crate.aliases,
        cfgs = crate.cfgs,
        compile_data = crate.compile_data,
        compile_data_targets = crate.compile_data_targets,
        data = crate.data,
        deps = crate.deps,
        edition = crate.edition,
        is_test = crate.is_test,
        metadata = crate.metadata,
        metadata_supports_pipelining = crate.metadata_supports_pipelining,
        name = crate.name,
        output = crate.output,
        owner = ctx.label,
        proc_macro_deps = crate.proc_macro_deps,
        root = crate.root,
        root_path = crate.root_path,
        rustc_env = crate.rustc_env,
        rustc_env_files = crate.rustc_env_files,
        rustc_output = crate.rustc_output,
        rustc_rmeta_output = crate.rustc_rmeta_output,
        srcs = crate.srcs,
        type = crate.type,
        wrapped_crate_type = crate.wrapped_crate_type,
    )
    return [
        DefaultInfo(files = depset([crate.output])),
        legacy,
    ]

legacy_crate = rule(
    implementation = _legacy_crate_impl,
    attrs = {
        "crate": attr.label(
            mandatory = True,
            providers = [rust_common.crate_info],
        ),
    },
)
