load("@bazel_tools//tools/build_defs/repo:utils.bzl", "get_auth")
load("@rules_rust//rust/platform:triple_mappings.bzl", "system_to_dylib_ext")

DEFAULT_STATIC_RUST_URL_TEMPLATES = ["https://static.rust-lang.org/dist/{}.tar.xz"]
RUST_REDIST_RELEASE_URL_TEMPLATE = "https://github.com/hermeticbuild/rust-redist/releases/download/{}/"

_rustc_lib_build_file_tmpl = """\
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

def check_version_valid(version, iso_date, param_prefix = ""):
    if not version and iso_date:
        fail("{param_prefix}iso_date must be paired with a {param_prefix}version".format(param_prefix = param_prefix))

    if version in ("beta", "nightly") and not iso_date:
        fail("{param_prefix}iso_date must be specified if version is 'beta' or 'nightly'".format(param_prefix = param_prefix))

def produce_tool_path(tool_name, version, target_triple = None):
    if not tool_name:
        fail("No tool name was provided")
    if not version:
        fail("No tool version was provided")

    platform_triple = target_triple.str if target_triple else None
    return "-".join([part for part in [tool_name, version, platform_triple] if part])

def produce_tool_suburl(tool_name, target_triple, version, iso_date = None):
    tool_path = produce_tool_path(tool_name, version, target_triple)
    if iso_date and version in ("beta", "nightly"):
        return iso_date + "/" + tool_path
    return tool_path

def includes_rust_analyzer_proc_macro_srv(version, iso_date):
    if version == "nightly":
        return iso_date >= "2022-09-21"
    if version == "beta":
        return False

    version_core = version.partition("+")[0].partition("-")[0]
    version_parts = version_core.split(".")
    if len(version_parts) != 3:
        fail("Unexpected number of parts for semver value: {}".format(version))

    major, minor, _patch = [int(part) for part in version_parts]
    return major >= 1 and minor >= 64

def rustc_lib_build_file(target_triple):
    return _rustc_lib_build_file_tmpl.format(
        dylib_ext = system_to_dylib_ext(target_triple.system),
        target_triple = target_triple.str,
    )

def rust_redist_manifest_url(version):
    return RUST_REDIST_RELEASE_URL_TEMPLATE.format(version) + "manifest.json"

def rust_redist_url_templates(version):
    return [RUST_REDIST_RELEASE_URL_TEMPLATE.format(version) + "{}.tar.zst"]

def rust_archive_extension(urls):
    url = urls[0] if urls else ""
    if url.endswith(".tar.gz"):
        return ".tar.gz"
    if url.endswith(".tar.xz"):
        return ".tar.xz"
    if url.endswith(".tar.zst"):
        return ".tar.zst"
    return ""

def rust_tool_archive(rctx, tool, dir, triple, sha256 = None):
    tool_suburl = produce_tool_suburl(tool, triple, rctx.attr.version, rctx.attr.iso_date)
    urls = [url.format(tool_suburl) for url in rctx.attr.urls]
    tool_path = produce_tool_path(tool, rctx.attr.version, triple)
    return struct(
        auth = get_auth(rctx, urls),
        output = tool_suburl.replace("/", "_").replace(":", "_") + rust_archive_extension(urls),
        sha256 = sha256 or rctx.attr.sha256,
        strip_prefix = "{}/{}".format(tool_path, dir),
        urls = urls,
    )

def download_and_extract(rctx, tool, dir, triple, sha256 = None):
    archive = rust_tool_archive(rctx, tool, dir, triple, sha256 = sha256)
    rctx.download_and_extract(
        archive.urls,
        sha256 = archive.sha256,
        auth = archive.auth,
        strip_prefix = archive.strip_prefix,
    )

RUST_REPOSITORY_COMMON_ATTR = {
    "triple": attr.string(mandatory = True),
    "version": attr.string(mandatory = True),
    "iso_date": attr.string(),
    "sha256": attr.string(mandatory = True),
    "urls": attr.string_list(default = DEFAULT_STATIC_RUST_URL_TEMPLATES),
}
