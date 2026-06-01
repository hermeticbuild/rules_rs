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

def _rustc_repository_impl(rctx):
    exec_triple = triple(rctx.attr.triple)
    download_and_extract(rctx, "rustc", "rustc", exec_triple)
    # Upstream Linux rustc bundles libLLVM, which dynamically links against libz.so.1.
    _add_linux_zlib(rctx, exec_triple)
    _symlink_rust_objcopy_shared_libraries(rctx, exec_triple)
    build_content = [BUILD_for_compiler(
        exec_triple,
        include_linker = True,
        include_objcopy = True,
    )]
    if includes_rust_analyzer_proc_macro_srv(rctx.attr.version, rctx.attr.iso_date):
        build_content.append(BUILD_for_rust_analyzer_proc_macro_srv(exec_triple))
    rctx.file("BUILD.bazel", "\n".join(build_content))

    return rctx.repo_metadata(reproducible = True)

rustc_repository = repository_rule(
    implementation = _rustc_repository_impl,
    attrs = RUST_REPOSITORY_COMMON_ATTR,
)
