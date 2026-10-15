"""Tests for Rust tool archive names and generated rustc_lib targets."""

load("@bazel_skylib//lib:unittest.bzl", "asserts", "unittest")
load("@rules_rust//rust/platform:triple.bzl", "triple")
load(
    ":rust_repository_utils.bzl",
    "DEFAULT_STATIC_RUST_URL_TEMPLATES",
    "includes_rust_analyzer_proc_macro_srv",
    "produce_tool_path",
    "produce_tool_suburl",
    "rust_archive_extension",
    "rust_redist_manifest_request",
    "rust_redist_manifest_url",
    "rust_redist_url_templates",
    "rustc_lib_build_file",
)

def _rust_tool_archive_names_test_impl(ctx):
    env = unittest.begin(ctx)
    linux_triple = triple("x86_64-unknown-linux-gnu")

    asserts.equals(env, ["https://static.rust-lang.org/dist/{}.tar.xz"], DEFAULT_STATIC_RUST_URL_TEMPLATES)
    asserts.equals(env, "rustc-1.92.0-x86_64-unknown-linux-gnu", produce_tool_path("rustc", "1.92.0", linux_triple))
    asserts.equals(env, "rust-src-1.92.0", produce_tool_path("rust-src", "1.92.0"))
    asserts.equals(env, "rustc-1.92.0-x86_64-unknown-linux-gnu", produce_tool_suburl("rustc", linux_triple, "1.92.0", "2026-04-20"))
    asserts.equals(env, "2026-04-20/rustc-nightly-x86_64-unknown-linux-gnu", produce_tool_suburl("rustc", linux_triple, "nightly", "2026-04-20"))
    asserts.equals(env, "2026-04-20/rust-src-beta", produce_tool_suburl("rust-src", None, "beta", "2026-04-20"))

    return unittest.end(env)

def _rust_archive_urls_test_impl(ctx):
    env = unittest.begin(ctx)

    asserts.equals(
        env,
        "https://github.com/hermeticbuild/rust-redist/releases/download/1.97.1/manifest.json",
        rust_redist_manifest_url("1.97.1"),
    )
    asserts.equals(
        env,
        ["https://github.com/hermeticbuild/rust-redist/releases/download/1.97.1/{}.tar.zst"],
        rust_redist_url_templates("1.97.1"),
    )
    asserts.equals(env, ".tar.zst", rust_archive_extension(rust_redist_url_templates("1.97.1")))
    asserts.equals(env, ".tar.xz", rust_archive_extension(DEFAULT_STATIC_RUST_URL_TEMPLATES))
    asserts.equals(env, ".tar.gz", rust_archive_extension(["https://static.rust-lang.org/dist/{}.tar.gz"]))
    asserts.equals(env, "", rust_archive_extension([]))

    return unittest.end(env)

def _rust_analyzer_proc_macro_srv_versions_test_impl(ctx):
    env = unittest.begin(ctx)

    asserts.false(env, includes_rust_analyzer_proc_macro_srv("1.63.0", None))
    asserts.true(env, includes_rust_analyzer_proc_macro_srv("1.64.0", None))
    asserts.true(env, includes_rust_analyzer_proc_macro_srv("1.92.0-alpha+build", None))
    asserts.false(env, includes_rust_analyzer_proc_macro_srv("beta", "2026-04-20"))
    asserts.false(env, includes_rust_analyzer_proc_macro_srv("nightly", "2022-09-20"))
    asserts.true(env, includes_rust_analyzer_proc_macro_srv("nightly", "2022-09-21"))

    return unittest.end(env)

def _rustc_lib_build_file_test_impl(ctx):
    env = unittest.begin(ctx)
    linux_content = rustc_lib_build_file(triple("x86_64-unknown-linux-gnu"))
    windows_content = rustc_lib_build_file(triple("aarch64-pc-windows-msvc"))

    asserts.true(env, 'name = "rustc_lib"' in linux_content)
    asserts.true(env, '"lib/*.so*"' in linux_content)
    asserts.true(env, "lib/rustlib/x86_64-unknown-linux-gnu/codegen-backends/*.so" in linux_content)
    asserts.true(env, "lib/rustlib/aarch64-pc-windows-msvc/codegen-backends/*.dll" in windows_content)

    return unittest.end(env)

def _rust_redist_manifest_request_test_impl(ctx):
    env = unittest.begin(ctx)
    url = rust_redist_manifest_url("1.92.0")
    archives = {
        "rustc-1.92.0-x86_64-unknown-linux-gnu.tar.zst": {"sha256": "rustc-sha"},
        "rust-src-1.92.0.tar.zst": {"sha256": "source-sha"},
    }
    downloads = []
    token = struct()

    def download(url, path, allow_fail, block):
        downloads.append(struct(url = url, path = path, allow_fail = allow_fail, block = block))
        return token

    mctx = struct(facts = {url: archives}, download = download)
    request = rust_redist_manifest_request(mctx, "1.92.0", refresh = False, required = True)
    asserts.equals(env, archives, request.archives)
    asserts.equals(env, None, request.token)
    asserts.equals(env, [], downloads)

    request = rust_redist_manifest_request(mctx, "1.92.0", refresh = True, required = True)
    asserts.equals(env, None, request.archives)
    asserts.equals(env, token, request.token)
    asserts.equals(env, "rust_redist_1.92.0_manifest.json", request.path)
    asserts.equals(env, url, downloads[-1].url)
    asserts.false(env, downloads[-1].allow_fail)
    asserts.false(env, downloads[-1].block)

    # A legacy lockfile has archive hashes but no complete manifest inventory.
    mctx = struct(facts = {"rustc-1.92.0-x86_64-unknown-linux-gnu.tar.zst": "rustc-sha"}, download = download)
    request = rust_redist_manifest_request(mctx, "1.92.0", refresh = False, required = True)
    asserts.equals(env, None, request.archives)
    asserts.false(env, downloads[-1].allow_fail)

    request = rust_redist_manifest_request(mctx, "1.93.0", refresh = False, required = False)
    asserts.equals(env, None, request.archives)
    asserts.equals(env, rust_redist_manifest_url("1.93.0"), downloads[-1].url)
    asserts.true(env, downloads[-1].allow_fail)

    request = rust_redist_manifest_request(struct(download = download), "1.92.0", refresh = False, required = False)
    asserts.equals(env, None, request.archives)
    asserts.true(env, downloads[-1].allow_fail)
    asserts.equals(env, 4, len(downloads))
    return unittest.end(env)

_rust_redist_manifest_request_test = unittest.make(_rust_redist_manifest_request_test_impl)
_rust_tool_archive_names_test = unittest.make(_rust_tool_archive_names_test_impl)
_rust_archive_urls_test = unittest.make(_rust_archive_urls_test_impl)
_rust_analyzer_proc_macro_srv_versions_test = unittest.make(_rust_analyzer_proc_macro_srv_versions_test_impl)
_rustc_lib_build_file_test = unittest.make(_rustc_lib_build_file_test_impl)

def rust_repository_utils_tests():
    return unittest.suite(
        "rust_repository_utils_tests",
        _rust_tool_archive_names_test,
        _rust_archive_urls_test,
        _rust_analyzer_proc_macro_srv_versions_test,
        _rustc_lib_build_file_test,
        _rust_redist_manifest_request_test,
    )
