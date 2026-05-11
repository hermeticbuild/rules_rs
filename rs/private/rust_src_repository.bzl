load("@bazel_tools//tools/build_defs/repo:utils.bzl", "get_auth")
load(
    "@rules_rust//rust/private:repository_utils.bzl",
    "DEFAULT_STATIC_RUST_URL_TEMPLATES",
    "produce_tool_path",
    "produce_tool_suburl",
)

def _rust_src_repository_impl(rctx):
    tool_suburl = produce_tool_suburl("rust-src", None, rctx.attr.version, rctx.attr.iso_date)
    urls = [url.format(tool_suburl) for url in rctx.attr.urls]

    tool_path = produce_tool_path("rust-src", rctx.attr.version)

    rctx.download_and_extract(
        urls,
        output = "lib/rustlib/src",
        sha256 = rctx.attr.sha256,
        auth = get_auth(rctx, urls),
        strip_prefix = "{}/rust-src/lib/rustlib/src/rust".format(tool_path),
    )
    rctx.file(
        "lib/rustlib/src/BUILD.bazel",
        """\
filegroup(
    name = "rustc_srcs",
    srcs = glob(["**/*"]),
    visibility = ["//visibility:public"],
)
""",
    )

    return rctx.repo_metadata(reproducible = True)

rust_src_repository = repository_rule(
    implementation = _rust_src_repository_impl,
    attrs = {
        "version": attr.string(mandatory = True),
        "iso_date": attr.string(),
        "sha256": attr.string(mandatory = True),
        "urls": attr.string_list(default = DEFAULT_STATIC_RUST_URL_TEMPLATES),
    },
)
