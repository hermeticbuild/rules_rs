load("@rules_rust//rust/platform:triple.bzl", "triple")
load(
    "@rules_rust//rust/private:repository_utils.bzl",
    "BUILD_for_rust_analyzer",
)
load(":rust_repository_utils.bzl", "RUST_REPOSITORY_COMMON_ATTR", "download_and_extract")

def _rust_analyzer_repository_impl(rctx):
    exec_triple = triple(rctx.attr.triple)
    download_and_extract(rctx, "rust-analyzer", "rust-analyzer-preview", exec_triple)
    rctx.file("BUILD.bazel", BUILD_for_rust_analyzer(exec_triple))

    return rctx.repo_metadata(reproducible = True)

rust_analyzer_repository = repository_rule(
    implementation = _rust_analyzer_repository_impl,
    attrs = RUST_REPOSITORY_COMMON_ATTR,
)
