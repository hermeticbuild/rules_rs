load("@rules_rust//rust/platform:triple.bzl", "triple")
load("@rules_rust//rust/platform:triple_mappings.bzl", "system_to_binary_ext", "system_to_dylib_ext")
load("//rs/private:rust_repository_utils.bzl", "RUST_REPOSITORY_COMMON_ATTR", "rust_tool_archive")

_BUILD_FOR_MIRI_TEMPLATE = """\
filegroup(
    name = "miri",
    srcs = ["bin/miri{binary_ext}"],
    visibility = ["//visibility:public"],
)

filegroup(
    name = "rustc_lib",
    srcs = glob(
        [
            "bin/*{dylib_ext}",
            "lib/*{dylib_ext}*",
            "lib/rustlib/{target_triple}/codegen-backends/*{dylib_ext}",
            "lib/rustlib/{target_triple}/lib/*{dylib_ext}*",
            "lib/rustlib/{target_triple}/lib/*.rmeta",
        ],
        allow_empty = True,
    ),
    visibility = ["//visibility:public"],
)
"""

def _miri_repository_impl(rctx):
    exec_triple = triple(rctx.attr.triple)
    miri = rust_tool_archive(rctx, "miri", "miri-preview", exec_triple)
    rustc = rust_tool_archive(rctx, "rustc", "rustc", exec_triple, sha256 = rctx.attr.rustc_sha256)
    miri_download = rctx.download(miri.urls, miri.output, sha256 = miri.sha256, auth = miri.auth, block = False)
    rustc_download = rctx.download(rustc.urls, rustc.output, sha256 = rustc.sha256, auth = rustc.auth, block = False)
    miri_download.wait()
    rustc_download.wait()
    rctx.extract(miri.output, strip_prefix = miri.strip_prefix)
    rctx.extract(rustc.output, strip_prefix = rustc.strip_prefix)
    rctx.file(
        "BUILD.bazel",
        _BUILD_FOR_MIRI_TEMPLATE.format(
            binary_ext = system_to_binary_ext(exec_triple.system),
            dylib_ext = system_to_dylib_ext(exec_triple.system),
            target_triple = exec_triple.str,
        ),
    )

    return rctx.repo_metadata(reproducible = True)

miri_repository = repository_rule(
    implementation = _miri_repository_impl,
    attrs = {
        "rustc_sha256": attr.string(mandatory = True),
    } | RUST_REPOSITORY_COMMON_ATTR,
)
