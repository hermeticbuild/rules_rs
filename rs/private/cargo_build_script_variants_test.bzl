"""Tests for selecting build-script requirements before the exec transition."""

load("@bazel_skylib//lib:unittest.bzl", "asserts", "loadingtest", "unittest")
load("//rs:cargo_build_script.bzl", "cargo_build_script")
load(":cargo_build_script_variants.bzl", "build_script_variants", "cargo_build_script_for_configurations", "cargo_build_script_for_targets")
load(":cargo_select.bzl", "cargo_select")

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

def _script_definition(features, context = None):
    return {
        "crate_features_select": features,
        "build_deps_by_target": {triple: {_MACOS: ["//:helper"]} for triple in features},
        "build_aliases_by_target": {triple: {"//:helper": "helper"} for triple in features},
        "build_contexts": {triple: triple if context == None else context for triple in features},
    }

def _configured_script_loading_tests():
    name = "configured_build_script"
    cargo_build_script_for_configurations(
        name = name,
        configurations = {
            "": _script_definition({_LINUX: ["normal_linux"], _MACOS: ["normal_macos"]}),
            _LINUX: _script_definition({_LINUX: ["execution"], _MACOS: ["execution"]}, _LINUX),
        },
        hub_name = "rules_rs",
        crate_features = ["common"],
        tags = ["manual"],
    )
    env = loadingtest.make(name)
    scripts = {
        _LINUX: ({"": _LINUX}, "normal_linux"),
        _MACOS: ({"": _MACOS}, "normal_macos"),
        _LINUX + "_" + _MACOS: ({_LINUX: _LINUX}, "execution"),
    }
    for representative, (contexts, feature) in scripts.items():
        binary = native.existing_rule(name + "_" + representative + "_")
        loadingtest.equals(env, representative + "_context", contexts, binary["cargo_contexts"])
        loadingtest.equals(env, representative + "_features", ["common", feature], list(binary["crate_features"]))
    loadingtest.equals(
        env,
        "script_count",
        len(scripts),
        len([target for target in native.existing_rules() if target.startswith(name + "_") and target.endswith("_")]),
    )
    native.alias(
        name = name + "_expected",
        actual = select({
            "@rules_rs//:__cargo/normal/" + _MACOS: ":" + name + "_" + _MACOS,
            "@rules_rs//:__cargo/normal/" + _LINUX: ":" + name + "_" + _LINUX,
            "@rules_rs//:__cargo/" + _LINUX + "/" + _MACOS: ":" + name + "_" + _LINUX + "_" + _MACOS,
            "@rules_rs//:__cargo/" + _LINUX + "/" + _LINUX: ":" + name + "_" + _LINUX + "_" + _MACOS,
        }),
        tags = ["manual"],
    )
    loadingtest.equals(env, "selection", str(native.existing_rule(name + "_expected")["actual"]), str(native.existing_rule(name)["actual"]))

    name = "configured_legacy_build_script"
    musl = "x86_64-unknown-linux-musl"
    cargo_build_script_for_configurations(
        name = name,
        configurations = {"": _script_definition({_LINUX: ["gnu"], musl: ["musl"], _MACOS: ["macos"]})},
        hub_name = "rules_rs",
        use_legacy_rules_rust_platforms = True,
        tags = ["manual"],
    )
    native.alias(
        name = name + "_expected",
        actual = select({
            "@rules_rs//:__cargo/normal/" + _MACOS: ":" + name + "_" + _MACOS,
            "@rules_rs//:__cargo/normal/" + musl: ":" + name + "_" + musl,
        }),
        tags = ["manual"],
    )
    loadingtest.equals(loadingtest.make(name), "selection", str(native.existing_rule(name + "_expected")["actual"]), str(native.existing_rule(name)["actual"]))

    name = "single_configured_build_script"
    cargo_build_script_for_configurations(
        name = name,
        configurations = {_LINUX: _script_definition({_MACOS: []}, _LINUX)},
        hub_name = "rules_rs",
        tags = ["manual"],
    )
    env = loadingtest.make(name)
    binary = native.existing_rule(name + "_")
    loadingtest.equals(env, "context", {_LINUX: _LINUX}, binary["cargo_contexts"])
    loadingtest.equals(env, "no_alias", False, "actual" in native.existing_rule(name))

    name = "invariant_build_script"
    definition = {
        "crate_features_select": {_LINUX: [], _MACOS: []},
        "build_deps_by_target": {},
        "build_aliases_by_target": {},
        "build_contexts": {_LINUX: "", _MACOS: ""},
    }
    cargo_build_script_for_configurations(
        name = name,
        configurations = {"": definition, _LINUX: definition},
        hub_name = "rules_rs",
        tags = ["manual"],
    )
    env = loadingtest.make(name)
    loadingtest.equals(env, "contexts", {"": "", _LINUX: ""}, native.existing_rule(name + "_")["cargo_contexts"])
    loadingtest.equals(env, "no_alias", False, "actual" in native.existing_rule(name))

    name = "first_party_build_script"
    cargo_build_script_for_configurations(
        name = name,
        configurations = {"": definition, _LINUX: definition},
        hub_name = "rules_rs",
        preserve_context = True,
        compile_data = ["//:generated_source"],
        tags = ["manual"],
    )
    env = loadingtest.make(name)
    loadingtest.equals(env, "normal_linux", {"": _LINUX, _LINUX: _LINUX}, native.existing_rule(name + "_" + _LINUX + "_")["cargo_contexts"])
    loadingtest.equals(env, "normal_macos", {"": _MACOS}, native.existing_rule(name + "_" + _MACOS + "_")["cargo_contexts"])

    name = "execution_alias_build_script"
    cargo_build_script_for_configurations(
        name = name,
        configurations = {_LINUX: {
            "crate_features_select": {_MACOS: []},
            "build_deps_by_target": {_MACOS: {
                _MACOS: ["//:shared", "//:macos"],
                _LINUX: ["//:shared", "//:linux"],
            }},
            "build_aliases_by_target": {_MACOS: {
                "//:shared": "shared",
                "//:macos": "macos",
                "//:linux": "linux",
                "//:unused": "unused",
            }},
            "build_contexts": {_MACOS: _LINUX},
        }},
        hub_name = "rules_rs",
        deps = ["//:annotation"],
        aliases = {"//:annotation": "annotated"},
        tags = ["manual"],
    )
    cargo_build_script(
        name = name + "_expected",
        aliases = select({
            "@rules_rs//rs/platforms/config:" + _MACOS: {"//:shared": "shared", "//:macos": "macos", "//:annotation": "annotated"},
            "@rules_rs//rs/platforms/config:" + _LINUX: {"//:shared": "shared", "//:linux": "linux", "//:annotation": "annotated"},
            "//conditions:default": {"//:shared": "shared", "//:annotation": "annotated"},
        }),
        tags = ["manual"],
    )
    env = loadingtest.make(name)
    loadingtest.equals(
        env,
        "aliases",
        str(native.existing_rule(name + "_expected_")["aliases"]),
        str(native.existing_rule(name + "_")["aliases"]),
    )
    loadingtest.equals(env, "annotated_context", {_LINUX: _LINUX}, native.existing_rule(name + "_")["cargo_contexts"])

    env = loadingtest.make("cargo_select_constants")
    loadingtest.equals(env, "shared", ["shared"], cargo_select({"": {_LINUX: ["shared"]}, _LINUX: {_MACOS: ["shared"]}}, "rules_rs"))
    loadingtest.equals(env, "empty", [], cargo_select({}, "rules_rs", default = []))
    loadingtest.equals(env, "default", {}, cargo_select({"": {_LINUX: {}}, _LINUX: {_MACOS: {}}}, "rules_rs", default = {}))

def cargo_build_script_variants_tests():
    _configured_script_loading_tests()
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
