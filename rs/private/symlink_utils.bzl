load("@bazel_features//:features.bzl", "bazel_features")
load("@bazel_lib//lib:paths.bzl", "relative_file")
load("@bazel_lib//lib:repo_utils.bzl", "repo_utils")

def _coreutils_label(rctx):
    platform = repo_utils.platform(rctx)
    binary = "coreutils.exe" if platform.startswith("windows_") else "coreutils"
    return Label("@coreutils_%s//:%s" % (platform, binary))

def relative_symlink(rctx, target, link_name):
    target_path = rctx.path(target)
    link_path = rctx.path(link_name)

    # Only use this when the target stays inside the same repository directory
    # that Bazel caches as a unit. Relative links to sibling external repos break
    # under repo_contents_cache because the cached repo is materialized alone.
    # Bazel before 9.0.1 writes absolute repository-rule symlinks, which makes
    # cached repositories point back at the original output base. Relative
    # symlinks survive repository_cache reuse across output bases.
    if bazel_features.external_deps.repo_rules_relativize_symlinks:
        rctx.symlink(target_path, link_path)
        return

    result = rctx.execute([
        _coreutils_label(rctx),
        "ln",
        "-sf",
        relative_file(str(target_path), str(link_path)),
        str(link_path),
    ])
    if result.return_code != 0:
        fail("symlink failed for {} -> {}: {}".format(link_path, target_path, result.stderr))
