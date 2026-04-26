load("@bazel_tools//tools/build_defs/repo:utils.bzl", "get_auth")
load(
    "@rules_rust//rust/private:repository_utils.bzl",
    "DEFAULT_STATIC_RUST_URL_TEMPLATES",
    "produce_tool_path",
    "produce_tool_suburl",
)

def _archive_extension(urls):
    url = urls[0] if urls else ""
    if url.endswith(".tar.gz"):
        return ".tar.gz"
    if url.endswith(".tar.xz"):
        return ".tar.xz"
    return ""

def rust_tool_archive(rctx, tool, dir, triple, sha256 = None):
    tool_suburl = produce_tool_suburl(tool, triple, rctx.attr.version, rctx.attr.iso_date)
    urls = [url.format(tool_suburl) for url in rctx.attr.urls]
    tool_path = produce_tool_path(tool, rctx.attr.version, triple)
    return struct(
        auth = get_auth(rctx, urls),
        output = tool_suburl.replace("/", "_").replace(":", "_") + _archive_extension(urls),
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
