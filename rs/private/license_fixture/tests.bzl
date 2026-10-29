"""Collect license artifacts starting at generated Rust libraries and binaries."""

load("@bazel_skylib//lib:shell.bzl", "shell")
load("@package_metadata//providers:package_metadata_info.bzl", "PackageMetadataInfo")
load("@rules_python//python:defs.bzl", "py_test")

_CollectedMetadataInfo = provider("Collected metadata artifacts.", fields = ["files"])

def _collect_impl(target, ctx):
    files = [target[PackageMetadataInfo].files] if PackageMetadataInfo in target else []
    for metadata in getattr(ctx.rule.attr, "package_metadata", []):
        if PackageMetadataInfo in metadata:
            files.append(metadata[PackageMetadataInfo].files)
    for dep in getattr(ctx.rule.attr, "deps", []):
        if _CollectedMetadataInfo in dep:
            files.append(dep[_CollectedMetadataInfo].files)
    return [_CollectedMetadataInfo(files = depset(transitive = files))]

_collect = aspect(implementation = _collect_impl, attr_aspects = ["deps"])

def _manifest_impl(ctx):
    files = ctx.attr.target[_CollectedMetadataInfo].files
    manifest = ctx.actions.declare_file(ctx.label.name + ".json")
    ctx.actions.write(manifest, json.encode([
        {
            "path": file.path,
            "runfile": file.short_path[3:] if file.short_path.startswith("../") else ctx.workspace_name + "/" + file.short_path,
        }
        for file in files.to_list()
    ]))
    return [DefaultInfo(files = depset([manifest]), runfiles = ctx.runfiles(transitive_files = files))]

_manifest = rule(
    implementation = _manifest_impl,
    attrs = {"target": attr.label(mandatory = True, aspects = [_collect])},
)

def license_test(name, target, purl, expression = "", original = None):
    """Check a generated crate's collected metadata and original license contents."""
    manifest = name + "_manifest"
    _manifest(name = manifest, target = target, testonly = True)
    py_test(
        name = name,
        srcs = [Label(":license_test.py")],
        main = Label(":license_test.py"),
        args = [
            "$(rlocationpath :%s)" % manifest,
            purl,
            shell.quote(expression),
        ] + (["$(rlocationpath %s)" % original] if original else []),
        data = [":" + manifest] + ([original] if original else []),
        deps = ["@rules_python//python/runfiles"],
    )
