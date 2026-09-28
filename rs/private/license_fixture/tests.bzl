"""Inspect the artifacts and provider closure consumed by metadata collectors."""

load("@bazel_skylib//lib:unittest.bzl", "analysistest", "asserts")
load("@package_metadata//providers:package_attribute_info.bzl", "PackageAttributeInfo")
load("@package_metadata//providers:package_metadata_info.bzl", "PackageMetadataInfo")

def _metadata_impl(ctx):
    env = analysistest.begin(ctx)
    info = analysistest.target_under_test(env)[PackageMetadataInfo]
    document = json.decode(analysistest.target_actions(env)[0].content)
    asserts.equals(env, ctx.attr.purl, document["purl"])
    asserts.equals(env, ["build.bazel.attribute.license"] if ctx.attr.licensed else [], document["attributes"].keys())
    asserts.equals(env, 1 + int(ctx.attr.licensed) + int(ctx.attr.with_file), len(info.files.to_list()))
    return analysistest.end(env)

metadata_test = analysistest.make(_metadata_impl, attrs = {"purl": attr.string(), "licensed": attr.bool(default = True), "with_file": attr.bool()})

def _license_impl(ctx):
    env = analysistest.begin(ctx)
    info = analysistest.target_under_test(env)[PackageAttributeInfo]
    document = json.decode(analysistest.target_actions(env)[0].content)
    asserts.equals(env, ctx.attr.expression, document["kind"]["identifier"])
    asserts.equals(env, "build.bazel.attribute.license", info.kind)
    files = [file for file in info.files.to_list() if file != info.attributes]
    asserts.equals(env, 1 if ctx.attr.with_file else 0, len(files))
    if ctx.attr.with_file:
        asserts.equals(env, files[0].path, document["text"])
        asserts.equals(env, "__rules_rs_cargo_license.txt", files[0].basename)
    else:
        asserts.false(env, "text" in document)
    return analysistest.end(env)

license_test = analysistest.make(_license_impl, attrs = {"expression": attr.string(), "with_file": attr.bool()})
