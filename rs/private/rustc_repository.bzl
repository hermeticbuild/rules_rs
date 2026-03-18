load("@rules_rust//rust/platform:triple.bzl", "triple")
load(
    "@rules_rust//rust/private:repository_utils.bzl",
    "BUILD_for_compiler",
    "BUILD_for_rust_analyzer_proc_macro_srv",
    "includes_rust_analyzer_proc_macro_srv",
)
load(":rust_repository_utils.bzl", "RUST_REPOSITORY_COMMON_ATTR", "download_and_extract")

def _rustc_repository_impl(rctx):
    exec_triple = triple(rctx.attr.triple)
    download_and_extract(rctx, "rustc", "rustc", exec_triple)
    build_content = [BUILD_for_compiler(exec_triple)]
    if includes_rust_analyzer_proc_macro_srv(rctx.attr.version, rctx.attr.iso_date):
        build_content.append(BUILD_for_rust_analyzer_proc_macro_srv(exec_triple))
    rctx.file("BUILD.bazel", "\n".join(build_content))

    return rctx.repo_metadata(reproducible = True)

rustc_repository = repository_rule(
    implementation = _rustc_repository_impl,
    attrs = RUST_REPOSITORY_COMMON_ATTR,
)
