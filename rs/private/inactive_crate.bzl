"""Metadata for dependency copies inspected and discarded by the compiler."""

load("@rules_rust//rust:rust_common.bzl", "CrateInfo", "DepInfo")

def _inactive_crate_impl(ctx):
    failed = ctx.attr.failed_compilation
    original = failed[CrateInfo]
    fields = {field: getattr(original, field) for field in dir(original) if field not in ["to_json", "to_proto"]}
    fields.update(
        owner = Label(ctx.attr.active_crate),
        compile_data = depset(transitive = [original.compile_data, failed[DefaultInfo].files]),
        root = ctx.file.crate_root,
        rustc_env = {},
        rustc_env_files = [],
        srcs = depset(ctx.files.srcs),
    )
    return [CrateInfo(**fields), failed[DepInfo], failed[DefaultInfo]]

# Do not name the backing edge deps, actual or crate: editor aspects should
# inspect this metadata without traversing its deliberately failing compilation.
# Its DefaultInfo still fails if a caller actually builds the inactive copy.
inactive_crate = rule(
    implementation = _inactive_crate_impl,
    attrs = {
        "active_crate": attr.string(mandatory = True),
        "crate_root": attr.label(mandatory = True, allow_single_file = [".rs"]),
        "failed_compilation": attr.label(mandatory = True, providers = [CrateInfo, DepInfo]),
        "srcs": attr.label_list(allow_files = [".rs"]),
    },
    provides = [CrateInfo, DepInfo],
)
