"""Tests for Cargo manifest values emitted into generated repositories."""

load("@bazel_skylib//lib:unittest.bzl", "asserts", "unittest")
load(":repository_utils.bzl", "cargo_build_file_values", "inherit_workspace_package_fields")

def _cargo_values(package, files = [], gen_build_script = "auto"):
    written = []

    def get_child(name):
        return struct(exists = name in files)

    def file(_path, content):
        written.append(content)

    rctx = struct(
        attr = struct(gen_build_script = gen_build_script),
        path = lambda _path: struct(get_child = get_child),
        file = file,
    )
    values = cargo_build_file_values(rctx, {"package": {"name": "sample"} | package}, [])
    return values.values, dict([line.split("=", 1) for line in written[0].splitlines()])

def _build_script_test_impl(ctx):
    env = unittest.begin(ctx)
    for package, files, expected in [
        ({}, [], "None"),
        ({}, ["build.rs"], repr("build.rs")),
        ({"build": False}, ["build.rs"], "None"),
        ({"build": True}, [], repr("build.rs")),
        ({"build": "./custom.rs"}, ["build.rs"], repr("custom.rs")),
        ({"build": "custom.rs"}, [], repr("custom.rs")),
        ({"build": True, "metadata": {"bazel": {"gen_build_script": False}}}, [], "None"),
    ]:
        values, _ = _cargo_values(package, files)
        asserts.equals(env, expected, values["build_script"])

    values, _ = _cargo_values({"build": True}, ["build.rs"], gen_build_script = "off")
    asserts.equals(env, "None", values["build_script"])
    return unittest.end(env)

def _readme_test_impl(ctx):
    env = unittest.begin(ctx)
    for package, files, expected in [
        ({}, [], ""),
        ({}, ["README", "README.txt", "README.md"], "README.md"),
        ({}, ["README", "README.txt"], "README.txt"),
        ({}, ["README"], "README"),
        ({"readme": False}, ["README.md"], ""),
        ({"readme": True}, [], "README.md"),
        ({"readme": "docs/about.md"}, ["README.md"], "docs/about.md"),
        ({"readme": ""}, ["README.md"], ""),
    ]:
        _, variables = _cargo_values(package, files)
        asserts.equals(env, expected, variables["CARGO_PKG_README"])
    return unittest.end(env)

def _package_metadata_test_impl(ctx):
    env = unittest.begin(ctx)
    workspace = {"workspace": {"package": {"license-file": "LICENSE", "rust-version": "1.85"}}}
    for package, workspace_manifest, expected_license, expected_rust_version in [
        ({}, workspace, "", ""),
        ({"license-file": "COPYING", "rust-version": "1.84"}, {}, "COPYING", "1.84"),
        ({"license-file": "COPYING", "rust-version": "1.84"}, workspace, "COPYING", "1.84"),
        ({"license-file": {"workspace": True}, "rust-version": {"workspace": True}}, workspace, "LICENSE", "1.85"),
    ]:
        manifest = {"package": package}
        inherited = inherit_workspace_package_fields(manifest, workspace_manifest)
        _, variables = _cargo_values(inherited["package"])
        asserts.equals(env, expected_license, variables["CARGO_PKG_LICENSE_FILE"])
        asserts.equals(env, expected_rust_version, variables["CARGO_PKG_RUST_VERSION"])

    workspace = {"workspace": {"package": {"authors": ["Ada", "Grace"]}}}
    for package, workspace_manifest, expected in [
        ({}, workspace, ""),
        ({"authors": ["Linus"]}, {}, "Linus"),
        ({"authors": ["Linus"]}, workspace, "Linus"),
        ({"authors": []}, workspace, ""),
        ({"authors": {"workspace": True}}, workspace, "Ada:Grace"),
    ]:
        manifest = {"package": package}
        inherited = inherit_workspace_package_fields(manifest, workspace_manifest)
        _, variables = _cargo_values(inherited["package"])
        asserts.equals(env, expected, variables["CARGO_PKG_AUTHORS"])
    return unittest.end(env)

_build_script_test = unittest.make(_build_script_test_impl)
_readme_test = unittest.make(_readme_test_impl)
_package_metadata_test = unittest.make(_package_metadata_test_impl)

def repository_utils_tests():
    _build_script_test(name = "repository_build_script_test")
    _readme_test(name = "repository_readme_test")
    _package_metadata_test(name = "repository_package_metadata_test")
    native.test_suite(
        name = "repository_utils_tests",
        tests = [":repository_build_script_test", ":repository_readme_test", ":repository_package_metadata_test"],
    )
