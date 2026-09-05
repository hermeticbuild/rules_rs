load("@rules_rust//rust/platform:triple.bzl", "triple")
load("@rules_rust//rust/platform:triple_mappings.bzl", "system_to_binary_ext")
load(":rust_repository_utils.bzl", "RUST_REPOSITORY_COMMON_ATTR", "download_and_extract", "includes_rust_analyzer_proc_macro_srv", "rustc_lib_build_file")

_build_file_tmpl = """\
filegroup(
    name = "rustc",
    srcs = ["bin/rustc{binary_ext}"],
    visibility = ["//visibility:public"],
)

filegroup(
    name = "rustdoc",
    srcs = ["bin/rustdoc{binary_ext}"],
    visibility = ["//visibility:public"],
)

{rustc_lib}

filegroup(
    name = "rust-lld",
    srcs = ["lib/rustlib/{target_triple}/bin/rust-lld{binary_ext}"],
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

filegroup(
    name = "rust-objcopy",
    srcs = glob(
        ["lib/rustlib/{target_triple}/bin/rust-objcopy{binary_ext}"],
        allow_empty = True,
    ),
    visibility = ["//visibility:public"],
)
"""

_proc_macro_srv_build_file_tmpl = """\
filegroup(
    name = "rust_analyzer_proc_macro_srv",
    srcs = ["libexec/rust-analyzer-proc-macro-srv{binary_ext}"],
    visibility = ["//visibility:public"],
)
"""

_LINUX_ZLIB = {
    "aarch64": struct(
        libdir = "usr/lib/aarch64-linux-gnu",
        sha256 = "e55ab3b4fb7b6edc4a628e28ec13f8780b08abe427d33ae148f030d8586d0e9a",
        url = "https://snapshot.ubuntu.com/ubuntu/20260901T000000Z/pool/main/z/zlib/zlib1g_1.3.dfsg-3.1ubuntu2.2_arm64.deb",
    ),
    "x86_64": struct(
        libdir = "usr/lib/x86_64-linux-gnu",
        sha256 = "84b9cf5752b29c9f92c27cd4c4ba9bbcc70b5ccf9b1b515421a28ae23212e273",
        url = "https://snapshot.ubuntu.com/ubuntu/20260901T000000Z/pool/main/z/zlib/zlib1g_1.3.dfsg-3.1ubuntu2.2_amd64.deb",
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
    binary_ext = system_to_binary_ext(exec_triple.system)
    download_and_extract(rctx, "rustc", "rustc", exec_triple)

    # Upstream Linux rustc bundles libLLVM, which dynamically links against libz.so.1.
    _add_linux_zlib(rctx, exec_triple)
    _symlink_rust_objcopy_shared_libraries(rctx, exec_triple)
    build_content = _build_file_tmpl.format(
        binary_ext = binary_ext,
        rustc_lib = rustc_lib_build_file(exec_triple),
        target_triple = exec_triple.str,
    )
    if includes_rust_analyzer_proc_macro_srv(rctx.attr.version, rctx.attr.iso_date):
        build_content += "\n" + _proc_macro_srv_build_file_tmpl.format(binary_ext = binary_ext)
    rctx.file("BUILD.bazel", build_content)

    return rctx.repo_metadata(reproducible = True)

rustc_repository = repository_rule(
    implementation = _rustc_repository_impl,
    attrs = RUST_REPOSITORY_COMMON_ATTR,
)
