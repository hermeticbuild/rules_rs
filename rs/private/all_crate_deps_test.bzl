load("@bazel_skylib//lib:partial.bzl", "partial")
load("@bazel_skylib//lib:unittest.bzl", "analysistest", "asserts", "unittest")
load(":all_crate_deps.bzl", "all_crate_deps", "crate_aliases", "crate_features", "merge_structured_dep_specs")
load(":cargo_select.bzl", "cargo_condition")

_LINUX = "x86_64-unknown-linux-gnu"
_MACOS = "aarch64-apple-darwin"

def _configured_data():
    return {
        "configurations": {
            "": {
                "crate_features_select": {_LINUX: ["target"], _MACOS: []},
                "deps_select": {_LINUX: ["@crates//:shared", "//helper"], _MACOS: []},
                "aliases": {"@crates//:shared": "selected_shared", "//helper": "renamed_helper"},
                "build_deps_by_target": {},
                "build_aliases_by_target": {},
                "build_contexts": {},
            },
            _LINUX: {
                "crate_features_select": {_MACOS: ["exec"]},
                "deps_select": {_MACOS: ["@crates//:shared", "@crates//:optional", "//helper"]},
                "aliases": {"@crates//:shared": "selected_shared", "@crates//:optional": "optional", "//helper": "renamed_helper"},
                "build_deps_by_target": {},
                "build_aliases_by_target": {},
                "build_contexts": {},
            },
        },
        "dev_deps": ["@crates//:dev", "//dev"],
        "dev_aliases": {"@crates//:dev": "dev", "//dev": "local_dev"},
    }

def _configured_dependencies_and_features_impl(ctx):
    env = unittest.begin(ctx)
    data = _configured_data()
    asserts.equals(env, str(select({
        cargo_condition("crates", "", _MACOS): [],
        cargo_condition("crates", "", _LINUX): ["//helper", "@crates//:shared"],
        cargo_condition("crates", _LINUX, _MACOS): ["//helper", "@crates//:optional", "@crates//:shared"],
    })), str(all_crate_deps(data, [], hub_name = "crates")))
    asserts.equals(env, str(select({
        cargo_condition("crates", "", _MACOS): ["@crates//:dev"],
        cargo_condition("crates", "", _LINUX): ["@crates//:dev", "@crates//:shared"],
        cargo_condition("crates", _LINUX, _MACOS): ["@crates//:dev", "@crates//:optional", "@crates//:shared"],
    })), str(all_crate_deps(data, [], normal = True, normal_dev = True, filter_prefix = "@crates//:", hub_name = "crates")))
    asserts.equals(env, str(select({
        cargo_condition("crates", "", _MACOS): [],
        cargo_condition("crates", "", _LINUX): ["target"],
        cargo_condition("crates", _LINUX, _MACOS): ["exec"],
    })), str(crate_features(data, "crates")))
    return unittest.end(env)

def _configured_aliases_match_selected_dependencies_impl(ctx):
    env = unittest.begin(ctx)
    data = _configured_data()
    asserts.equals(env, str(select({
        cargo_condition("crates", "", _MACOS): {},
        cargo_condition("crates", "", _LINUX): {"//helper": "renamed_helper", "@crates//:shared": "selected_shared"},
        cargo_condition("crates", _LINUX, _MACOS): {"//helper": "renamed_helper", "@crates//:optional": "optional", "@crates//:shared": "selected_shared"},
    })), str(crate_aliases(data, normal = True, hub_name = "crates")))
    return unittest.end(env)

def _merge_structured_dep_specs_dedupes_and_promotes_impl(ctx):
    env = unittest.begin(ctx)

    specs = [
        (
            ["@repo//:shared", "@repo//:dup"],
            {
                "//cfg:unix": ["@repo//:linux_only", "@repo//:dup"],
                "//cfg:darwin": ["@repo//:darwin_only"],
            },
        ),
        (
            [],
            {
                "//cfg:unix": ["@repo//:everywhere"],
                "//cfg:darwin": ["@repo//:everywhere", "@repo//:darwin_only"],
                "//cfg:win": ["@repo//:everywhere"],
            },
        ),
    ]

    shared, per_platform = merge_structured_dep_specs(
        specs,
        ["//cfg:darwin", "//cfg:unix", "//cfg:win"],
        None,
    )

    asserts.equals(env, ["@repo//:dup", "@repo//:everywhere", "@repo//:shared"], shared)
    asserts.equals(env, {
        "//cfg:darwin": ["@repo//:darwin_only"],
        "//cfg:unix": ["@repo//:linux_only"],
    }, per_platform)

    return unittest.end(env)

def _merge_structured_dep_specs_applies_filter_prefix_impl(ctx):
    env = unittest.begin(ctx)

    shared, per_platform = merge_structured_dep_specs(
        [
            (
                ["@repo//:shared", "@other//:drop"],
                {
                    "//cfg:linux": ["@repo//:linux_only", "@other//:drop"],
                },
            ),
        ],
        ["//cfg:darwin", "//cfg:linux"],
        "@repo//:",
    )

    asserts.equals(env, ["@repo//:shared"], shared)
    asserts.equals(env, {"//cfg:linux": ["@repo//:linux_only"]}, per_platform)

    return unittest.end(env)

def _all_crate_deps_defaults_to_normal_impl(ctx):
    env = unittest.begin(ctx)

    got = all_crate_deps(
        {
            "deps": ["//:normal"],
            "deps_by_platform": {},
            "build_deps": ["//:build"],
            "build_deps_by_platform": {},
            "dev_deps": ["//:dev"],
            "dev_deps_by_platform": {},
        },
        platforms = ["//cfg:darwin", "//cfg:linux"],
    )

    asserts.equals(env, ["//:normal"], got)

    return unittest.end(env)

def _all_crate_deps_dedupes_across_selected_kinds_impl(ctx):
    env = unittest.begin(ctx)

    got = all_crate_deps(
        {
            "deps": [],
            "deps_by_platform": {
                "//cfg:linux": ["//:dep_a", "//:dep_b"],
            },
            "build_deps": [],
            "build_deps_by_platform": {},
            "dev_deps": ["//:dep_b"],
            "dev_deps_by_platform": {
                "//cfg:linux": ["//:dep_a", "//:dep_c"],
            },
        },
        platforms = ["//cfg:linux"],
        normal = True,
        normal_dev = True,
    )

    asserts.equals(env, ["//:dep_a", "//:dep_b", "//:dep_c"], got)

    return unittest.end(env)

def _build_data():
    helper = "@crates//:helper"
    return {
        "configurations": {"": {
            "crate_features_select": {_LINUX: ["linux_feature"], _MACOS: ["macos_feature"]},
            "deps_select": {},
            "aliases": {},
            "build_deps_by_target": {
                triple: {_LINUX: [helper], _MACOS: [helper]}
                for triple in [_LINUX, _MACOS]
            },
            "build_aliases_by_target": {triple: {helper: "helper"} for triple in [_LINUX, _MACOS]},
            "build_contexts": {triple: "" for triple in [_LINUX, _MACOS]},
        }},
    }

def _all_crate_deps_invariant_build_deps_ignore_features_impl(ctx):
    env = unittest.begin(ctx)
    data = _build_data()
    asserts.equals(env, ["@crates//:helper"], all_crate_deps(data, [], build = True, hub_name = "crates"))
    asserts.equals(env, {"@crates//:helper": "helper"}, crate_aliases(data, build = True, hub_name = "crates"))
    return unittest.end(env)

def _all_crate_deps_selects_execution_platform_impl(ctx):
    env = unittest.begin(ctx)
    data = _build_data()
    data["configurations"][""]["build_deps_by_target"] = {
        triple: {_LINUX: ["@crates//:linux_helper"], _MACOS: ["@crates//:macos_helper"]}
        for triple in [_LINUX, _MACOS]
    }
    asserts.equals(env, str(select({
        cargo_condition("crates", "", _MACOS): ["@crates//:macos_helper"],
        cargo_condition("crates", "", _LINUX): ["@crates//:linux_helper"],
    })), str(all_crate_deps(data, [], build = True, hub_name = "crates")))
    return unittest.end(env)

def _all_crate_deps_preserves_build_context_impl(ctx):
    env = unittest.begin(ctx)
    definition = _build_data()["configurations"][""]
    definition["build_contexts"] = {triple: _LINUX for triple in [_LINUX, _MACOS]}
    data = {"configurations": {_LINUX: definition}}
    asserts.equals(env, ["@crates//:helper"], all_crate_deps(data, [], build = True, hub_name = "crates"))
    return unittest.end(env)

def _build_aliases_ignore_unrenamed_dependencies_impl(ctx):
    env = unittest.begin(ctx)
    data = _build_data()
    definition = data["configurations"][""]
    definition["deps_select"] = {_LINUX: ["//:linux_normal"], _MACOS: ["//:macos_normal"]}
    definition["aliases"] = {"//:linux_normal": "normal", "//:macos_normal": "normal"}
    definition["build_contexts"] = {_LINUX: _LINUX, _MACOS: _MACOS}
    definition["build_deps_by_target"] = {
        _LINUX: {_LINUX: ["@crates//:helper", "//:linux_build"], _MACOS: ["//:linux_build"]},
        _MACOS: {_LINUX: ["@crates//:helper", "//:macos_build"], _MACOS: ["//:macos_build"]},
    }
    data["dev_deps"] = ["//:dev"]
    data["dev_aliases"] = {"//:dev": "dev"}
    asserts.equals(env, str(select({
        cargo_condition("crates", "", _MACOS): {},
        cargo_condition("crates", "", _LINUX): {"@crates//:helper": "helper"},
    })), str(crate_aliases(data, build = True, hub_name = "crates")))
    asserts.equals(env, str(select({
        cargo_condition("crates", "", _MACOS): {"//:dev": "dev", "//:macos_normal": "normal"},
        cargo_condition("crates", "", _LINUX): {"//:dev": "dev", "//:linux_normal": "normal", "@crates//:helper": "helper"},
    })), str(crate_aliases(data, hub_name = "crates")))
    return unittest.end(env)

def _all_crate_deps_preserves_build_platform_domain_impl(ctx):
    env = unittest.begin(ctx)
    wasm = "wasm32-unknown-unknown"
    data = _build_data()
    definition = data["configurations"][""]
    definition["crate_features_select"] = {wasm: []}
    definition["deps_select"] = {wasm: ["//:normal"]}
    definition["build_deps_by_target"] = {wasm: {_LINUX: ["@crates//:helper"], _MACOS: ["@crates//:helper"]}}
    asserts.equals(env, str(select({
        cargo_condition("crates", "", _MACOS): ["@crates//:helper"],
        cargo_condition("crates", "", wasm): ["//:normal"],
        cargo_condition("crates", "", _LINUX): ["@crates//:helper"],
    })), str(all_crate_deps(data, [], normal = True, build = True, hub_name = "crates")))
    definition["build_deps_by_target"] = {wasm: {_LINUX: [], _MACOS: []}}
    asserts.equals(env, str(select({
        cargo_condition("crates", "", _MACOS): [],
        cargo_condition("crates", "", wasm): ["//:normal"],
        cargo_condition("crates", "", _LINUX): [],
    })), str(all_crate_deps(data, [], normal = True, build = True, hub_name = "crates")))
    return unittest.end(env)

def _ambiguous_build_script_impl(ctx):
    data = _build_data()
    definition = data["configurations"][""]
    if ctx.attr.field == "aliases":
        definition["build_aliases_by_target"][_MACOS] = {"@crates//:helper": "other_name"}
        crate_aliases(data, build = True, hub_name = "crates")
    elif ctx.attr.field == "alias_platforms":
        definition["build_deps_by_target"][_MACOS][_LINUX] = []
        crate_aliases(data, build = True, hub_name = "crates")
    elif ctx.attr.field == "context":
        definition["build_contexts"][_LINUX] = _LINUX
        all_crate_deps(data, [], build = True, hub_name = "crates")
    else:
        definition["build_deps_by_target"][_MACOS] = {_MACOS: ["@crates//:other_helper"]}
        all_crate_deps(data, [], build = True, hub_name = "crates")
    return []

_ambiguous_build_script = rule(
    implementation = _ambiguous_build_script_impl,
    attrs = {"field": attr.string()},
)

def _ambiguous_build_script_test_impl(ctx):
    env = analysistest.begin(ctx)
    asserts.expect_failure(env, "Use cargo_build_script from the generated Cargo repository's defs.bzl.")
    return analysistest.end(env)

ambiguous_build_script_test = analysistest.make(_ambiguous_build_script_test_impl, expect_failure = True)

merge_structured_dep_specs_dedupes_and_promotes_test = unittest.make(_merge_structured_dep_specs_dedupes_and_promotes_impl)
merge_structured_dep_specs_applies_filter_prefix_test = unittest.make(_merge_structured_dep_specs_applies_filter_prefix_impl)
all_crate_deps_defaults_to_normal_test = unittest.make(_all_crate_deps_defaults_to_normal_impl)
all_crate_deps_dedupes_across_selected_kinds_test = unittest.make(_all_crate_deps_dedupes_across_selected_kinds_impl)
all_crate_deps_invariant_build_deps_ignore_features_test = unittest.make(_all_crate_deps_invariant_build_deps_ignore_features_impl)
all_crate_deps_selects_execution_platform_test = unittest.make(_all_crate_deps_selects_execution_platform_impl)
all_crate_deps_preserves_build_context_test = unittest.make(_all_crate_deps_preserves_build_context_impl)
all_crate_deps_preserves_build_platform_domain_test = unittest.make(_all_crate_deps_preserves_build_platform_domain_impl)
build_aliases_ignore_unrenamed_dependencies_test = unittest.make(_build_aliases_ignore_unrenamed_dependencies_impl)
configured_dependencies_and_features_test = unittest.make(_configured_dependencies_and_features_impl)
configured_aliases_match_selected_dependencies_test = unittest.make(_configured_aliases_match_selected_dependencies_impl)

def all_crate_deps_tests():
    for field in ["aliases", "alias_platforms", "context", "deps"]:
        _ambiguous_build_script(
            name = "ambiguous_build_script_" + field,
            field = field,
            tags = ["manual"],
        )
    return unittest.suite(
        "all_crate_deps_tests",
        merge_structured_dep_specs_dedupes_and_promotes_test,
        merge_structured_dep_specs_applies_filter_prefix_test,
        all_crate_deps_defaults_to_normal_test,
        all_crate_deps_dedupes_across_selected_kinds_test,
        all_crate_deps_invariant_build_deps_ignore_features_test,
        all_crate_deps_selects_execution_platform_test,
        all_crate_deps_preserves_build_context_test,
        all_crate_deps_preserves_build_platform_domain_test,
        build_aliases_ignore_unrenamed_dependencies_test,
        configured_dependencies_and_features_test,
        configured_aliases_match_selected_dependencies_test,
        partial.make(ambiguous_build_script_test, target_under_test = ":ambiguous_build_script_deps"),
        partial.make(ambiguous_build_script_test, target_under_test = ":ambiguous_build_script_aliases"),
        partial.make(ambiguous_build_script_test, target_under_test = ":ambiguous_build_script_alias_platforms"),
        partial.make(ambiguous_build_script_test, target_under_test = ":ambiguous_build_script_context"),
    )
