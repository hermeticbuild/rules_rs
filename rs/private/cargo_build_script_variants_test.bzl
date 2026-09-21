"""Tests for selecting build-script requirements before the exec transition."""

load("@bazel_skylib//lib:unittest.bzl", "asserts", "loadingtest", "unittest")
load(":cargo_build_script_variants.bzl", "build_script_variants", "cargo_build_script_for_targets")

_LINUX = "x86_64-unknown-linux-gnu"
_MACOS = "aarch64-apple-darwin"
_WINDOWS = "x86_64-pc-windows-msvc"

def _identical_recipes_share_script_impl(ctx):
    env = unittest.begin(ctx)
    variants = build_script_variants(
        crate_features_select = {_LINUX: ["b", "a", "b"], _MACOS: ["a", "b"]},
        build_deps_by_target = {
            _LINUX: {_LINUX: ["//:b", "//:a"], _MACOS: ["//:a", "//:b"]},
            _MACOS: {_MACOS: ["//:b", "//:a"], _LINUX: ["//:a", "//:b", "//:a"]},
        },
        build_aliases_by_target = {
            _LINUX: {"//:a": "renamed_a", "//:b": "renamed_b"},
            _MACOS: {"//:b": "renamed_b", "//:a": "renamed_a"},
        },
        use_legacy_rules_rust_platforms = False,
    )
    asserts.equals(env, [{
        "target_triples": [_MACOS, _LINUX],
        "crate_features": ["a", "b"],
        "deps": ["//:a", "//:b"],
        "deps_by_platform": {},
        "aliases": {"//:a": "renamed_a", "//:b": "renamed_b"},
    }], variants)
    return unittest.end(env)

def _target_features_split_scripts_impl(ctx):
    env = unittest.begin(ctx)
    variants = build_script_variants(
        crate_features_select = {_WINDOWS: ["vendored"], _LINUX: ["vendored"], _MACOS: []},
        build_deps_by_target = {},
        build_aliases_by_target = {},
        use_legacy_rules_rust_platforms = False,
    )
    asserts.equals(env, 2, len(variants))
    asserts.equals(env, [_MACOS], variants[0]["target_triples"])
    asserts.equals(env, [], variants[0]["crate_features"])
    asserts.equals(env, [_WINDOWS, _LINUX], variants[1]["target_triples"])
    asserts.equals(env, ["vendored"], variants[1]["crate_features"])
    return unittest.end(env)

def _target_deps_split_scripts_with_same_features_impl(ctx):
    env = unittest.begin(ctx)
    variants = build_script_variants(
        crate_features_select = {_LINUX: [], _MACOS: []},
        build_deps_by_target = {
            _LINUX: {_LINUX: ["//:linux_feature"], _MACOS: ["//:linux_feature"]},
            _MACOS: {_LINUX: ["//:macos_feature"], _MACOS: ["//:macos_feature"]},
        },
        build_aliases_by_target = {},
        use_legacy_rules_rust_platforms = False,
    )
    asserts.equals(env, 2, len(variants))
    for variant in variants:
        triple = variant["target_triples"][0]
        dep = "//:linux_feature" if triple == _LINUX else "//:macos_feature"
        asserts.equals(env, [dep], variant["deps"])
        asserts.equals(env, {}, variant["deps_by_platform"])
        asserts.equals(env, [], variant["crate_features"])
    return unittest.end(env)

def _execution_deps_remain_separate_impl(ctx):
    env = unittest.begin(ctx)
    deps = {_LINUX: ["//:shared", "//:linux_host"], _MACOS: ["//:macos_host", "//:shared"]}
    variants = build_script_variants(
        crate_features_select = {_LINUX: [], _MACOS: []},
        build_deps_by_target = {_LINUX: deps, _MACOS: deps},
        build_aliases_by_target = {},
        use_legacy_rules_rust_platforms = False,
    )
    asserts.equals(env, 1, len(variants))
    asserts.equals(env, ["//:shared"], variants[0]["deps"])
    asserts.equals(env, {
        "@rules_rs//rs/platforms/config:" + _LINUX: ["//:linux_host"],
        "@rules_rs//rs/platforms/config:" + _MACOS: ["//:macos_host"],
    }, variants[0]["deps_by_platform"])
    return unittest.end(env)

def _target_aliases_split_scripts_impl(ctx):
    env = unittest.begin(ctx)
    deps = {_LINUX: ["//:shared"], _MACOS: ["//:shared"]}
    variants = build_script_variants(
        crate_features_select = {_LINUX: [], _MACOS: []},
        build_deps_by_target = {_LINUX: deps, _MACOS: deps},
        build_aliases_by_target = {
            _LINUX: {"//:shared": "linux_name"},
            _MACOS: {"//:shared": "macos_name"},
        },
        use_legacy_rules_rust_platforms = False,
    )
    asserts.equals(env, 2, len(variants))
    asserts.equals(env, {"//:shared": "macos_name"}, variants[0]["aliases"])
    asserts.equals(env, {"//:shared": "linux_name"}, variants[1]["aliases"])
    return unittest.end(env)

def _empty_dependencies_share_script_impl(ctx):
    env = unittest.begin(ctx)
    variants = build_script_variants(
        crate_features_select = {_LINUX: [], _MACOS: []},
        build_deps_by_target = {_LINUX: {_LINUX: [], _MACOS: []}},
        build_aliases_by_target = {},
        use_legacy_rules_rust_platforms = False,
    )
    asserts.equals(env, 1, len(variants))
    asserts.equals(env, [_MACOS, _LINUX], variants[0]["target_triples"])
    asserts.equals(env, [], variants[0]["deps"])
    asserts.equals(env, {}, variants[0]["deps_by_platform"])
    asserts.equals(env, [{
        "target_triples": [""],
        "crate_features": [],
        "deps": [],
        "deps_by_platform": {},
        "aliases": {},
    }], build_script_variants({}, {}, {}, False))
    return unittest.end(env)

def _common_features_preserve_target_domain_impl(ctx):
    env = unittest.begin(ctx)
    variants = build_script_variants(
        crate_features_select = {_LINUX: ["linux", "common"], _MACOS: [], _WINDOWS: []},
        build_deps_by_target = {},
        build_aliases_by_target = {},
        use_legacy_rules_rust_platforms = False,
        crate_features = ["common", "legacy", "common"],
    )
    asserts.equals(env, 2, len(variants))
    asserts.equals(env, [_MACOS, _WINDOWS], variants[0]["target_triples"])
    asserts.equals(env, ["common", "legacy"], variants[0]["crate_features"])
    asserts.equals(env, [_LINUX], variants[1]["target_triples"])
    asserts.equals(env, ["common", "legacy", "linux"], variants[1]["crate_features"])
    asserts.equals(env, ["common"], build_script_variants({}, {}, {}, False, crate_features = ["common"])[0]["crate_features"])
    return unittest.end(env)

def _legacy_platform_dependencies_share_script_impl(ctx):
    env = unittest.begin(ctx)
    musl = "x86_64-unknown-linux-musl"
    variants = build_script_variants(
        crate_features_select = {_LINUX: [], _MACOS: []},
        build_deps_by_target = {
            _LINUX: {_LINUX: ["//:gnu"], musl: ["//:musl"], _MACOS: []},
            _MACOS: {_LINUX: ["//:musl", "//:gnu"], musl: [], _MACOS: []},
        },
        build_aliases_by_target = {},
        use_legacy_rules_rust_platforms = True,
    )
    asserts.equals(env, 1, len(variants))
    asserts.equals(env, [_MACOS, _LINUX], variants[0]["target_triples"])
    asserts.equals(env, [], variants[0]["deps"])
    asserts.equals(env, {
        "@rules_rust//rust/platform:" + _LINUX: ["//:gnu", "//:musl"],
    }, variants[0]["deps_by_platform"])
    return unittest.end(env)

identical_recipes_share_script_test = unittest.make(_identical_recipes_share_script_impl)
target_features_split_scripts_test = unittest.make(_target_features_split_scripts_impl)
target_deps_split_scripts_with_same_features_test = unittest.make(_target_deps_split_scripts_with_same_features_impl)
execution_deps_remain_separate_test = unittest.make(_execution_deps_remain_separate_impl)
target_aliases_split_scripts_test = unittest.make(_target_aliases_split_scripts_impl)
empty_dependencies_share_script_test = unittest.make(_empty_dependencies_share_script_impl)
common_features_preserve_target_domain_test = unittest.make(_common_features_preserve_target_domain_impl)
legacy_platform_dependencies_share_script_test = unittest.make(_legacy_platform_dependencies_share_script_impl)

def cargo_build_script_variants_tests():
    name = "legacy_platform_build_script"
    cargo_build_script_for_targets(
        name = name,
        build_scripts = build_script_variants(
            {_MACOS: ["vendored"], _LINUX: [], "x86_64-unknown-linux-musl": ["vendored"]},
            {},
            {},
            True,
        ),
        use_legacy_rules_rust_platforms = True,
        tags = ["manual"],
    )
    native.alias(
        name = name + "_expected",
        actual = select({
            "@rules_rust//rust/platform:" + _MACOS: ":" + name + "_" + _MACOS,
            "@rules_rust//rust/platform:" + _LINUX: ":" + name + "_" + _MACOS,
        }),
        tags = ["manual"],
    )
    loadingtest.equals(
        loadingtest.make(name),
        "selection",
        str(native.existing_rule(name + "_expected")["actual"]),
        str(native.existing_rule(name)["actual"]),
    )

    return unittest.suite(
        "cargo_build_script_variants_tests",
        identical_recipes_share_script_test,
        target_features_split_scripts_test,
        target_deps_split_scripts_with_same_features_test,
        execution_deps_remain_separate_test,
        target_aliases_split_scripts_test,
        empty_dependencies_share_script_test,
        common_features_preserve_target_domain_test,
        legacy_platform_dependencies_share_script_test,
    )
