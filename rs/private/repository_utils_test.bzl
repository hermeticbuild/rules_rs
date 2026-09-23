"""Tests for Cargo configuration data in generated BUILD files."""

load("@bazel_skylib//lib:partial.bzl", "partial")
load("@bazel_skylib//lib:unittest.bzl", "analysistest", "asserts", "unittest")
load(":repository_utils.bzl", "render_rust_crate_call")

_LINUX = "x86_64-unknown-linux-gnu"
_MACOS = "aarch64-apple-darwin"

def _attrs(configurations = None, cargo_target_triple_map = {}, **kwargs):
    fields = dict(
        allow_build_script_to_detect_nonhermetic_paths = False,
        build_script_data = [],
        build_script_data_select = {},
        build_script_env = {},
        build_script_env_select = {},
        build_script_tags = [],
        build_script_toolchains = [],
        build_script_tools = [],
        build_script_tools_select = {},
        cargo_target_triple_map = cargo_target_triple_map,
        configurations = json.encode({"": _configuration()} if configurations == None else configurations),
        crate_tags = [],
        data = [],
        deps = [],
        hub_name = "crates",
        rustc_env = {},
        rustc_flags = [],
        rustc_flags_select = {},
        use_legacy_rules_rust_platforms = False,
    )
    fields.update(kwargs)
    return struct(**fields)

def _configuration(**kwargs):
    return dict(
        crate_features_by_triple = {_LINUX: []},
        deps_by_triple = {_LINUX: {}},
        build_deps_by_triple = {},
        build_cargo_target_triple_required_on = [],
    ) | kwargs

def _values(binaries = {}):
    return {
        "binaries": repr(binaries),
        "build_script": repr("build.rs"),
        "crate_name": "None",
        "crate_root": repr("src/lib.rs"),
        "edition": repr("2021"),
        "has_lib": "True",
        "is_proc_macro": "False",
        "links": "None",
        "name": repr("example"),
        "purl": repr("pkg:cargo/example@1.0.0"),
        "version": repr("1.0.0"),
    }

def _argument(rendered, name):
    return json.decode(rendered.split("    " + name + " = ")[1].split(",\n")[0])

def _single_crate_test_impl(ctx):
    env = unittest.begin(ctx)
    configurations = {
        "": _configuration(
            crate_features_by_triple = {_LINUX: ["normal_feature"]},
            deps_by_triple = {_LINUX: {"@dependency//:normal": "normal"}},
            build_deps_by_triple = {_LINUX: {_MACOS: {"@helper//:helper": "helper"}}},
        ),
        _LINUX: _configuration(
            crate_features_by_triple = {_MACOS: ["build_feature"]},
            deps_by_triple = {_MACOS: {"@dependency//:build": "build"}},
        ),
    }
    cargo_target_triple_map = {_MACOS: ""}
    binaries = {"example-cli": "src/main.rs"}
    rendered = render_rust_crate_call(
        _attrs(configurations = configurations, cargo_target_triple_map = cargo_target_triple_map),
        _values(binaries = binaries),
    )
    asserts.equals(env, 1, rendered.count("rust_crate("))
    asserts.equals(env, configurations, _argument(rendered, "configurations"))
    asserts.equals(env, cargo_target_triple_map, _argument(rendered, "cargo_target_triple_map"))
    asserts.equals(env, binaries, _argument(rendered, "binaries"))
    asserts.equals(env, "crates", _argument(rendered, "hub_name"))
    return unittest.end(env)

def _annotation_and_git_values_test_impl(ctx):
    env = unittest.begin(ctx)
    values = _values() | {
        "binaries": "binaries",
        "build_script": "build_script",
        "crate_name": "crate_name",
        "has_lib": "has_lib",
        "is_proc_macro": "is_proc_macro",
    }
    rendered = render_rust_crate_call(
        _attrs(
            configurations = {_LINUX: _configuration()},
            cargo_target_triple_map = {"": _LINUX},
            deps = ["//annotated:dep"],
        ),
        values,
        bazel_metadata = {"deps": ["//metadata:dep"]},
        extra_deps = "package_metadata_bazel_deps",
        indent = "    ",
    )
    for name in ["binaries", "build_script", "crate_name", "has_lib", "is_proc_macro"]:
        asserts.true(env, "        " + name + " = " + name + "," in rendered)
    asserts.true(env, '"//annotated:dep"' in rendered)
    asserts.true(env, '"//metadata:dep"' in rendered)
    asserts.true(env, " + package_metadata_bazel_deps" in rendered)
    return unittest.end(env)

def _undeclared_metadata_deps_impl(ctx):
    render_rust_crate_call(
        _attrs(cargo_target_triple_map = {_LINUX: ""}),
        _values(),
        bazel_metadata = {"deps": ["//metadata:dep"]},
    )
    return []

_undeclared_metadata_deps = rule(implementation = _undeclared_metadata_deps_impl)

def _undeclared_metadata_deps_test_impl(ctx):
    env = analysistest.begin(ctx)
    asserts.expect_failure(env, "Declare package.metadata.bazel.deps in crate.annotation(deps = ...)")
    return analysistest.end(env)

_undeclared_metadata_deps_test = analysistest.make(_undeclared_metadata_deps_test_impl, expect_failure = True)

def _source_attributes_test_impl(ctx):
    env = unittest.begin(ctx)
    rendered = render_rust_crate_call(
        _attrs(
            hub_name = None,
            extra_compile_data = ["//src/library/core:srcs"],
            rustc_env = {"RUSTC_BOOTSTRAP": "1"},
            rustc_flags = ["-Zforce-unstable-if-unmarked"],
        ),
        _values(),
        skip_deps_verification = True,
    )
    asserts.equals(env, ["-Zforce-unstable-if-unmarked"], _argument(rendered, "rustc_flags"))
    asserts.equals(env, "1", _argument(rendered, "rustc_env")["RUSTC_BOOTSTRAP"])
    asserts.true(env, "hub_name = None" in rendered)
    asserts.true(env, '"//src/library/core:srcs"' in rendered)
    asserts.true(env, "skip_deps_verification = True" in rendered)
    return unittest.end(env)

_single_crate_test = unittest.make(_single_crate_test_impl)
_annotation_and_git_values_test = unittest.make(_annotation_and_git_values_test_impl)
_source_attributes_test = unittest.make(_source_attributes_test_impl)

def repository_utils_tests():
    _undeclared_metadata_deps(name = "undeclared_metadata_deps", tags = ["manual"])
    return unittest.suite(
        "repository_utils_tests",
        _single_crate_test,
        _annotation_and_git_values_test,
        _source_attributes_test,
        partial.make(_undeclared_metadata_deps_test, target_under_test = ":undeclared_metadata_deps"),
    )
