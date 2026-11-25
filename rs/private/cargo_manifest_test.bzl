"""Tests for Cargo manifest values emitted into generated repositories."""

load("@bazel_skylib//lib:unittest.bzl", "analysistest", "asserts", "unittest")
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

def _disabled_workspace_readme_impl(_ctx):
    workspace_dir = struct(get_child = lambda name: struct(exists = name == "README.md", is_dir = False))
    inherit_workspace_package_fields(
        rctx = struct(read = lambda _path: "workspace readme", file = lambda _path, _content, executable: None),
        cargo_toml = {"package": {"readme": {"workspace": True}}},
        workspace_cargo_toml = {"workspace": {"package": {"readme": False}}},
        workspace_dir = workspace_dir,
        package_dir = struct(get_child = lambda name: name),
    )
    return []

def _inherited_readme_test_impl(ctx):
    env = analysistest.begin(ctx)
    asserts.expect_failure(env, "Missing workspace.package.readme")
    return analysistest.end(env)

_disabled_workspace_readme = rule(implementation = _disabled_workspace_readme_impl)
_inherited_readme_failure_test = analysistest.make(_inherited_readme_test_impl, expect_failure = True)
_build_script_test = unittest.make(_build_script_test_impl)
_readme_test = unittest.make(_readme_test_impl)

def _inherited_readme_test(name):
    subject = name + "_subject"
    _disabled_workspace_readme(name = subject, tags = ["manual"])
    _inherited_readme_failure_test(name = name, target_under_test = ":" + subject)

def cargo_manifest_tests():
    _build_script_test(name = "repository_build_script_test")
    _readme_test(name = "repository_readme_test")
    _inherited_readme_test(name = "repository_inherited_readme_test")
    native.test_suite(
        name = "cargo_manifest_tests",
        tests = [":repository_build_script_test", ":repository_readme_test", ":repository_inherited_readme_test"],
    )
