"""Repository rule for the llvm-tools component of a Rust release."""

load("@rules_rust//rust/platform:triple.bzl", "triple")
load("@rules_rust//rust/platform:triple_mappings.bzl", "system_to_binary_ext")
load(":rust_repository_utils.bzl", "RUST_REPOSITORY_COMMON_ATTR", "download_and_extract")

_build_file_tmpl = """\
filegroup(
    name = "llvm_cov_bin",
    srcs = ["lib/rustlib/{triple}/bin/llvm-cov{binary_ext}"],
    visibility = ["//visibility:public"],
)

filegroup(
    name = "llvm_profdata_bin",
    srcs = ["lib/rustlib/{triple}/bin/llvm-profdata{binary_ext}"],
    visibility = ["//visibility:public"],
)

# Linux binaries load libLLVM from here through an $ORIGIN/../lib rpath.
filegroup(
    name = "llvm_lib",
    srcs = glob(["lib/rustlib/{triple}/lib/**"], allow_empty = True),
    visibility = ["//visibility:public"],
)
"""

def _llvm_tools_repository_impl(rctx):
    exec_triple = triple(rctx.attr.triple)
    download_and_extract(rctx, "llvm-tools", "llvm-tools-preview", exec_triple)
    rctx.file(
        "BUILD.bazel",
        _build_file_tmpl.format(
            binary_ext = system_to_binary_ext(exec_triple.system),
            triple = exec_triple.str,
        ),
    )

    return rctx.repo_metadata(reproducible = True)

llvm_tools_repository = repository_rule(
    implementation = _llvm_tools_repository_impl,
    attrs = RUST_REPOSITORY_COMMON_ATTR,
)
