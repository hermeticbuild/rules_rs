load("@bazel_features//:features.bzl", "bazel_features")
load("@rules_rust//rust/platform:triple.bzl", "triple")
load(
    "@rules_rust//rust/private:repository_utils.bzl",
    "BUILD_for_compiler",
)

def _symlink_children(rctx, source_dir, destination_dir):
    if not source_dir.exists or not source_dir.is_dir:
        return

    rctx.file("{}/.generated".format(destination_dir), "")
    for entry in source_dir.readdir():
        if entry.is_dir or entry.basename.startswith("."):
            continue

        destination = "{}/{}".format(destination_dir, entry.basename)
        if not rctx.path(destination).exists:
            rctx.symlink(entry, destination)

def _rustc_with_dev_repository_impl(rctx):
    exec_triple = triple(rctx.attr.triple)
    rustc_repo_root = rctx.path(rctx.attr.rustc_repo_build_file).dirname
    rustc_dev_repo_root = rctx.path(rctx.attr.rustc_dev_repo_build_file).dirname

    # Keep the ordinary rustc repository lean. This merged sysroot is materialized
    # only when a dev-enabled toolchain is actually selected.
    rctx.symlink(rustc_repo_root.get_child("bin"), "bin")

    rustc_lib_root = rustc_repo_root.get_child("lib")
    rustc_rustlib_root = rustc_lib_root.get_child("rustlib").get_child(exec_triple.str)
    rustc_dev_lib_root = rustc_dev_repo_root.get_child("lib").get_child("rustlib").get_child(exec_triple.str)

    _symlink_children(rctx, rustc_lib_root, "lib")
    rctx.symlink(
        rustc_rustlib_root.get_child("bin"),
        "lib/rustlib/{}/bin".format(exec_triple.str),
    )
    _symlink_children(
        rctx,
        rustc_rustlib_root.get_child("codegen-backends"),
        "lib/rustlib/{}/codegen-backends".format(exec_triple.str),
    )
    _symlink_children(
        rctx,
        rustc_rustlib_root.get_child("lib"),
        "lib/rustlib/{}/lib".format(exec_triple.str),
    )
    _symlink_children(
        rctx,
        rustc_dev_lib_root.get_child("lib"),
        "lib/rustlib/{}/lib".format(exec_triple.str),
    )

    # `rustc_private` crates link against compiler `.rlib`s from rustc-dev.
    # The upstream compiler BUILD omits `.rlib`s because ordinary toolchains do
    # not need them, so extend the merged sysroot manifest only for this variant.
    build_file = BUILD_for_compiler(exec_triple, include_objcopy = True)
    build_file = build_file.replace(
        '"lib/rustlib/{}/lib/*.rmeta",'.format(exec_triple.str),
        '\n'.join([
            '"lib/rustlib/{}/lib/*.rmeta",'.format(exec_triple.str),
            '            "lib/rustlib/{}/lib/*.rlib",'.format(exec_triple.str),
        ]),
    )
    rctx.file("BUILD.bazel", build_file)

    return rctx.repo_metadata(
        reproducible = bazel_features.external_deps.repo_rules_relativize_symlinks,
    )

rustc_with_dev_repository = repository_rule(
    implementation = _rustc_with_dev_repository_impl,
    attrs = {
        "rustc_repo_build_file": attr.label(allow_single_file = True, mandatory = True),
        "rustc_dev_repo_build_file": attr.label(allow_single_file = True, mandatory = True),
        "triple": attr.string(mandatory = True),
    },
)
