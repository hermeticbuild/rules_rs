load("@rules_rust//rust/platform:triple.bzl", "triple")
load(
    "@rules_rust//rust/private:repository_utils.bzl",
    "BUILD_for_compiler",
    "BUILD_for_rust_analyzer_proc_macro_srv",
    "includes_rust_analyzer_proc_macro_srv",
)
load(":rust_repository_utils.bzl", "RUST_REPOSITORY_COMMON_ATTR", "download_and_extract")

_LINUX_ZLIB = {
    "aarch64": struct(
        libdir = "usr/lib/aarch64-linux-gnu",
        sha256 = "cbe3d39ec32d3cc27c021ae4af11e7c67bdf9d700d573207e0941d4038056278",
        url = "https://ports.ubuntu.com/ubuntu-ports/pool/main/z/zlib/zlib1g_1.3.dfsg-3.1ubuntu2.1_arm64.deb",
    ),
    "x86_64": struct(
        libdir = "usr/lib/x86_64-linux-gnu",
        sha256 = "7074b6a2f6367a10d280c00a1cb02e74277709180bab4f2491a2f355ab2d6c20",
        url = "https://archive.ubuntu.com/ubuntu/pool/main/z/zlib/zlib1g_1.3.dfsg-3.1ubuntu2.1_amd64.deb",
    ),
}

def _extract_deb_payload(rctx, url, sha256, output, strip_prefix):
    deb_dir = ".zlib_deb"
    rctx.download_and_extract(
        url = url,
        sha256 = sha256,
        output = deb_dir,
        type = ".deb",
    )

    data_archive = deb_dir + "/data.tar.zst"
    if not rctx.path(data_archive).exists:
        fail("expected data.tar.zst in {}".format(url))

    rctx.extract(data_archive, output = output, stripPrefix = strip_prefix)
    rctx.delete(deb_dir)

def _add_linux_zlib(rctx, exec_triple):
    if exec_triple.system != "linux":
        return

    zlib = _LINUX_ZLIB[exec_triple.arch]
    _extract_deb_payload(rctx, zlib.url, zlib.sha256, "lib", zlib.libdir)

def _symlink_rust_objcopy_shared_libraries(rctx, exec_triple):
    top_level_lib = rctx.path("lib")
    rustlib_lib = "lib/rustlib/{}/lib".format(exec_triple.str)
    rctx.file("{}/.generated".format(rustlib_lib), "")

    for entry in top_level_lib.readdir():
        # Rust's rust-objcopy has RUNPATH=$ORIGIN/../lib, so mirror its
        # bundled runtime library into the location the binary expects.
        if entry.basename.startswith("libLLVM"):
            rctx.symlink(entry, "{}/{}".format(rustlib_lib, entry.basename))

# Routes the macOS rust-lld through the sanitize_rust_lld rule (see that file for
# why this is a build action and not repository-rule work). The public rust-lld
# filegroup interface is preserved: srcs is the sanitized binary, data carries
# the auxiliary linker tools unchanged. exec_compatible_with pins the action to a
# macOS execution platform so it lands on the laptop or macOS RBE worker that
# actually uses rust-lld.
_MACOS_RUST_LLD_LOAD = 'load("@rules_rs//rs/private:sanitize_rust_lld.bzl", "sanitize_rust_lld")'

_MACOS_RUST_LLD_BUILD = """\
sanitize_rust_lld(
    name = "sanitized-rust-lld",
    src = "lib/rustlib/{target_triple}/bin/rust-lld{binary_ext}",
    target_triple = "{target_triple}",
    exec_compatible_with = ["@platforms//os:macos"],
)

filegroup(
    name = "rust-lld",
    srcs = [":sanitized-rust-lld"],
    data = glob(
        include = [
            "lib/rustlib/{target_triple}/bin/*-ld{binary_ext}",
            "lib/rustlib/{target_triple}/bin/gcc-ld/*",
        ],
        exclude = [
            "lib/rustlib/{target_triple}/bin/rust-lld{binary_ext}",
        ],
        allow_empty = True,
    ),
    visibility = ["//visibility:public"],
)
"""

def _rustc_repository_impl(rctx):
    exec_triple = triple(rctx.attr.triple)
    download_and_extract(rctx, "rustc", "rustc", exec_triple)

    # Upstream Linux rustc bundles libLLVM, which dynamically links against libz.so.1.
    _add_linux_zlib(rctx, exec_triple)
    _symlink_rust_objcopy_shared_libraries(rctx, exec_triple)

    is_macos = exec_triple.system == "macos"

    # On macOS the linker filegroup is emitted by _MACOS_RUST_LLD_BUILD below so
    # that rust-lld is routed through the rpath-sanitizing rule; everywhere else
    # the upstream linker filegroup is used unchanged.
    build_content = []
    if is_macos:
        build_content.append(_MACOS_RUST_LLD_LOAD)
    build_content.append(BUILD_for_compiler(
        exec_triple,
        include_linker = not is_macos,
        include_objcopy = True,
    ))
    if is_macos:
        build_content.append(_MACOS_RUST_LLD_BUILD.format(
            binary_ext = "",
            target_triple = exec_triple.str,
        ))
    if includes_rust_analyzer_proc_macro_srv(rctx.attr.version, rctx.attr.iso_date):
        build_content.append(BUILD_for_rust_analyzer_proc_macro_srv(exec_triple))
    rctx.file("BUILD.bazel", "\n".join(build_content))

    return rctx.repo_metadata(reproducible = True)

rustc_repository = repository_rule(
    implementation = _rustc_repository_impl,
    attrs = RUST_REPOSITORY_COMMON_ATTR,
)
