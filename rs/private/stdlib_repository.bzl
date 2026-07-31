load("@rules_rust//rust/platform:triple.bzl", "triple")
load("@rules_rust//rust/platform:triple_mappings.bzl", "system_to_dylib_ext", "system_to_staticlib_ext")
load(":rust_repository_utils.bzl", "RUST_REPOSITORY_COMMON_ATTR", "download_and_extract")

_build_file_tmpl = """\
load("@rules_rust//rust:rust_stdlib_filegroup.bzl", "rust_stdlib_filegroup")

rust_stdlib_filegroup(
    name = "rust_std-{target_triple}",
    srcs = glob(
        [
            "lib/rustlib/{target_triple}/lib/*.rlib",
            "lib/rustlib/{target_triple}/lib/*.rmeta",
            "lib/rustlib/{target_triple}/lib/*{dylib_ext}*",
            "lib/rustlib/{target_triple}/lib/*{staticlib_ext}",
            "lib/rustlib/{target_triple}/lib/self-contained/**",
        ],
        allow_empty = True,
    ),
    visibility = ["//visibility:public"],
)

alias(
    name = "rust_lib-{target_triple}",
    actual = "rust_std-{target_triple}",
    visibility = ["//visibility:public"],
)
"""

def _stdlib_repository_impl(rctx):
    target = triple(rctx.attr.triple)
    download_and_extract(rctx, "rust-std", "rust-std-{}".format(target.str), target)
    rctx.file(
        "BUILD.bazel",
        _build_file_tmpl.format(
            dylib_ext = system_to_dylib_ext(target.system),
            staticlib_ext = system_to_staticlib_ext(target.system),
            target_triple = target.str,
        ),
    )

    return rctx.repo_metadata(reproducible = True)

stdlib_repository = repository_rule(
    implementation = _stdlib_repository_impl,
    attrs = RUST_REPOSITORY_COMMON_ATTR,
)
