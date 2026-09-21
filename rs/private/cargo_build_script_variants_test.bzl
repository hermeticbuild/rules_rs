"""Tests for selecting build-script requirements before the exec transition."""

load("@bazel_skylib//lib:unittest.bzl", "asserts", "unittest")
load(":cargo_build_script_variants.bzl", "build_script_variants")

_LINUX = "x86_64-unknown-linux-gnu"
_MACOS = "aarch64-apple-darwin"
_WINDOWS = "x86_64-pc-windows-msvc"

def _profile(features = [], deps = {}, aliases = {}):
    return {"features": features, "deps": deps, "aliases": aliases}

def _identical_recipes_share_script_impl(ctx):
    env = unittest.begin(ctx)
    variants = build_script_variants({
        _LINUX: _profile(
            features = ["b", "a", "b"],
            deps = {_LINUX: ["//:b", "//:a"], _MACOS: ["//:a", "//:b"]},
            aliases = {"//:a": "renamed_a", "//:b": "renamed_b"},
        ),
        _MACOS: _profile(
            features = ["a", "b"],
            deps = {_MACOS: ["//:b", "//:a"], _LINUX: ["//:a", "//:b", "//:a"]},
            aliases = {"//:b": "renamed_b", "//:a": "renamed_a"},
        ),
    })
    asserts.equals(env, [{
        "triples": [_MACOS, _LINUX],
        "crate_features": ["a", "b"],
        "deps": {_MACOS: ["//:a", "//:b"], _LINUX: ["//:a", "//:b"]},
        "aliases": {"//:a": "renamed_a", "//:b": "renamed_b"},
    }], variants)
    return unittest.end(env)

def _target_features_split_scripts_impl(ctx):
    env = unittest.begin(ctx)
    variants = build_script_variants({
        _WINDOWS: _profile(features = ["vendored"]),
        _LINUX: _profile(features = ["vendored"]),
        _MACOS: _profile(),
    })
    asserts.equals(env, 2, len(variants))
    asserts.equals(env, [_MACOS], variants[0]["triples"])
    asserts.equals(env, [], variants[0]["crate_features"])
    asserts.equals(env, [_WINDOWS, _LINUX], variants[1]["triples"])
    asserts.equals(env, ["vendored"], variants[1]["crate_features"])
    return unittest.end(env)

def _target_deps_split_scripts_with_same_features_impl(ctx):
    env = unittest.begin(ctx)
    variants = build_script_variants({
        _LINUX: _profile(deps = {_LINUX: ["//:linux_feature"], _MACOS: ["//:linux_feature"]}),
        _MACOS: _profile(deps = {_LINUX: ["//:macos_feature"], _MACOS: ["//:macos_feature"]}),
    })
    asserts.equals(env, 2, len(variants))
    for variant in variants:
        triple = variant["triples"][0]
        dep = "//:linux_feature" if triple == _LINUX else "//:macos_feature"
        asserts.equals(env, {_LINUX: [dep], _MACOS: [dep]}, variant["deps"])
        asserts.equals(env, [], variant["crate_features"])
    return unittest.end(env)

def _execution_deps_remain_separate_impl(ctx):
    env = unittest.begin(ctx)
    deps = {_LINUX: ["//:linux_host"], _MACOS: ["//:macos_host"]}
    variants = build_script_variants({
        _LINUX: _profile(deps = deps),
        _MACOS: _profile(deps = deps),
    })
    asserts.equals(env, 1, len(variants))
    asserts.equals(env, deps, variants[0]["deps"])
    return unittest.end(env)

def _target_aliases_split_scripts_impl(ctx):
    env = unittest.begin(ctx)
    deps = {_LINUX: ["//:shared"], _MACOS: ["//:shared"]}
    variants = build_script_variants({
        _LINUX: _profile(deps = deps, aliases = {"//:shared": "linux_name"}),
        _MACOS: _profile(deps = deps, aliases = {"//:shared": "macos_name"}),
    })
    asserts.equals(env, 2, len(variants))
    asserts.equals(env, {"//:shared": "macos_name"}, variants[0]["aliases"])
    asserts.equals(env, {"//:shared": "linux_name"}, variants[1]["aliases"])
    return unittest.end(env)

def _empty_dependencies_share_script_impl(ctx):
    env = unittest.begin(ctx)
    variants = build_script_variants({
        _LINUX: _profile(deps = {_LINUX: [], _MACOS: []}),
        _MACOS: _profile(),
    })
    asserts.equals(env, 1, len(variants))
    asserts.equals(env, {}, variants[0]["deps"])
    asserts.equals(env, [{"triples": [""], "crate_features": [], "deps": {}, "aliases": {}}], build_script_variants({}))
    return unittest.end(env)

identical_recipes_share_script_test = unittest.make(_identical_recipes_share_script_impl)
target_features_split_scripts_test = unittest.make(_target_features_split_scripts_impl)
target_deps_split_scripts_with_same_features_test = unittest.make(_target_deps_split_scripts_with_same_features_impl)
execution_deps_remain_separate_test = unittest.make(_execution_deps_remain_separate_impl)
target_aliases_split_scripts_test = unittest.make(_target_aliases_split_scripts_impl)
empty_dependencies_share_script_test = unittest.make(_empty_dependencies_share_script_impl)

def cargo_build_script_variants_tests():
    return unittest.suite(
        "cargo_build_script_variants_tests",
        identical_recipes_share_script_test,
        target_features_split_scripts_test,
        target_deps_split_scripts_with_same_features_test,
        execution_deps_remain_separate_test,
        target_aliases_split_scripts_test,
        empty_dependencies_share_script_test,
    )
