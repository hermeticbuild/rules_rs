load("@rules_rust//rust/platform:triple.bzl", "triple")
load(":rust_repository_utils.bzl", "RUST_REPOSITORY_COMMON_ATTR", "download_and_extract")

def _rustc_dev_repository_impl(rctx):
    exec_triple = triple(rctx.attr.triple)
    download_and_extract(rctx, "rustc-dev", "rustc-dev", exec_triple)

    rctx.file(
        "BUILD.bazel",
        """\
filegroup(
    name = "rustc_dev_libs",
    srcs = glob(
        ["lib/rustlib/{triple}/lib/*.rlib"],
        allow_empty = True,
    ),
    visibility = ["//visibility:public"],
)
""".format(triple = exec_triple.str),
    )

    return rctx.repo_metadata(reproducible = True)

rustc_dev_repository = repository_rule(
    implementation = _rustc_dev_repository_impl,
    attrs = RUST_REPOSITORY_COMMON_ATTR,
)
