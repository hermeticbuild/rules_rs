"""Tests for Cargo manifest values emitted into generated repositories."""

load("@bazel_skylib//lib:unittest.bzl", "asserts", "unittest")
load(":repository_utils.bzl", "cargo_build_file_values")

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

_build_script_test = unittest.make(_build_script_test_impl)
_readme_test = unittest.make(_readme_test_impl)

def cargo_manifest_tests():
    _build_script_test(name = "repository_build_script_test")
    _readme_test(name = "repository_readme_test")
    native.test_suite(
        name = "cargo_manifest_tests",
        tests = [":repository_build_script_test", ":repository_readme_test"],
    )
