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

def normalize_rust_version(version):
    """Converts dated rustup toolchain names to rules_rs version syntax.

    Args:
      version: A Rust release or dated channel name.

    Returns:
      The version with a slash separating a prerelease channel and its date.
    """
    for channel in ("beta", "nightly"):
        prefix = channel + "-"
        if version.startswith(prefix):
            return channel + "/" + version.removeprefix(prefix)
    return version

def is_pinned_rust_version(version):
    """Checks whether a canonical Rust version identifies an immutable release.

    Args:
      version: A version returned by normalize_rust_version.

    Returns:
      Whether the version is X.Y.Z or a valid dated beta/nightly.
    """
    parts = version.split("/")
    if len(parts) == 1:
        numbers = version.split(".")
        return len(numbers) == 3 and all([number.isdigit() and (number == "0" or not number.startswith("0")) for number in numbers])
    if len(parts) != 2 or parts[0] not in ("beta", "nightly"):
        return False
    date = parts[1].split("-")
    if len(date) != 3 or [len(part) for part in date] != [4, 2, 2] or not all([part.isdigit() for part in date]):
        return False
    year, month, day = [int(part) for part in date]
    if year == 0 or month < 1 or month > 12:
        return False
    leap_year = year % 4 == 0 and (year % 100 != 0 or year % 400 == 0)
    month_days = [31, 29 if leap_year else 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]
    return day >= 1 and day <= month_days[month - 1]

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
