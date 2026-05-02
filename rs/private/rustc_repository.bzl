load("@rules_rust//rust/platform:triple.bzl", "triple")
load(
    "@rules_rust//rust/private:repository_utils.bzl",
    "BUILD_for_compiler",
    "BUILD_for_rust_analyzer_proc_macro_srv",
    "includes_rust_analyzer_proc_macro_srv",
)
load(":rust_repository_utils.bzl", "RUST_REPOSITORY_COMMON_ATTR", "download_and_extract")

def _symlink_rust_objcopy_shared_libraries(rctx, exec_triple):
    rust_objcopy = rctx.path("lib/rustlib/{}/bin/rust-objcopy".format(exec_triple.str))
    if not rust_objcopy.exists:
        rust_objcopy = rctx.path("lib/rustlib/{}/bin/rust-objcopy.exe".format(exec_triple.str))
    if not rust_objcopy.exists:
        return

    top_level_lib = rctx.path("lib")
    rustlib_lib = "lib/rustlib/{}/lib".format(exec_triple.str)
    rctx.file("{}/.generated".format(rustlib_lib), "")

    for entry in top_level_lib.readdir():
        # Rust's rust-objcopy has RUNPATH=$ORIGIN/../lib, so mirror its
        # bundled runtime library into the location the binary expects.
        if entry.basename.startswith("libLLVM"):
            rctx.symlink(entry, "{}/{}".format(rustlib_lib, entry.basename))

def _rustc_repository_impl(rctx):
    exec_triple = triple(rctx.attr.triple)
    download_and_extract(rctx, "rustc", "rustc", exec_triple)
    if rctx.attr.rustc_dev_sha256:
        # `rustc-dev` supplies the compiler-internal crates that custom lint
        # libraries need when they use `#![feature(rustc_private)]`.
        download_and_extract(
            rctx,
            "rustc-dev",
            "rustc-dev",
            exec_triple,
            sha256 = rctx.attr.rustc_dev_sha256,
        )
    _symlink_rust_objcopy_shared_libraries(rctx, exec_triple)
    build_content = [BUILD_for_compiler(exec_triple, include_objcopy = True)]
    if rctx.attr.rustc_dev_sha256:
        build_content.append("""\
filegroup(
    name = "rustc_dev_libs",
    srcs = glob(
        [
            "lib/rustlib/{triple}/lib/*.rlib",
        ],
        allow_empty = True,
    ),
    visibility = ["//visibility:public"],
)

filegroup(
    name = "rustc_lib_with_dev",
    srcs = [
        ":rustc_lib",
        ":rustc_dev_libs",
    ],
    visibility = ["//visibility:public"],
)""".format(triple = exec_triple.str))
    if includes_rust_analyzer_proc_macro_srv(rctx.attr.version, rctx.attr.iso_date):
        build_content.append(BUILD_for_rust_analyzer_proc_macro_srv(exec_triple))
    rctx.file("BUILD.bazel", "\n".join(build_content))

    return rctx.repo_metadata(reproducible = True)

rustc_repository = repository_rule(
    implementation = _rustc_repository_impl,
    attrs = {
        "rustc_dev_sha256": attr.string(),
    } | RUST_REPOSITORY_COMMON_ATTR,
)
