"""Cargo workspace package inheritance regressions (issue #273)."""

load("@bazel_skylib//lib:unittest.bzl", "asserts", "unittest")
load(":repository_utils.bzl", "inherit_workspace_package_fields")

def _inheritance_impl(ctx):
    env = unittest.begin(ctx)
    package = {field: {"workspace": True} for field in ["authors", "rust-version", "license-file", "readme", "version", "keywords", "include", "publish"]}
    package["name"] = "member"
    manifest = {"package": package}
    workspace = {"workspace": {"package": {
        "authors": ["Example Author"],
        "rust-version": "1.85",
        "license-file": "LICENSE",
        "readme": "docs/README.md",
        "version": "2.0.0",
        "keywords": ["example"],
        "include": ["src/**"],
        "publish": False,
    }}}
    inherited = inherit_workspace_package_fields(manifest, workspace, "../../")
    asserts.equals(env, "../../LICENSE", inherited["package"]["license-file"])
    asserts.equals(env, "../../docs/README.md", inherited["package"]["readme"])
    for field in ["authors", "rust-version", "version", "keywords", "include", "publish"]:
        asserts.equals(env, workspace["workspace"]["package"][field], inherited["package"][field])
    asserts.equals(env, {"workspace": True}, manifest["package"]["version"])
    return unittest.end(env)

def _explicit_values_impl(ctx):
    env = unittest.begin(ctx)
    manifest = {"package": {"name": "member", "version": "1", "readme": False, "license-file": "local.txt"}}
    workspace = {"workspace": {"package": {"version": "2", "readme": "README.md", "license-file": "LICENSE"}}}
    asserts.equals(env, manifest, inherit_workspace_package_fields(manifest, workspace, "../"))
    inherited = inherit_workspace_package_fields({"package": {"readme": {"workspace": True}}}, {"workspace": {"package": {"readme": False}}}, "../")
    asserts.equals(env, False, inherited["package"]["readme"])
    asserts.equals(env, manifest, inherit_workspace_package_fields(manifest, {}))
    return unittest.end(env)

_inheritance_test = unittest.make(_inheritance_impl)
_explicit_values_test = unittest.make(_explicit_values_impl)

def repository_utils_tests():
    unittest.suite("repository_utils_tests", _inheritance_test, _explicit_values_test)
