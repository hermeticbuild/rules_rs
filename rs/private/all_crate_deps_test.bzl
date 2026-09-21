load("@bazel_skylib//lib:partial.bzl", "partial")
load("@bazel_skylib//lib:unittest.bzl", "analysistest", "asserts", "unittest")
load(":all_crate_deps.bzl", "all_crate_deps", "crate_aliases", "merge_structured_dep_specs")

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

_BUILD_PLATFORMS = ["//cfg:linux_exec", "//cfg:macos_exec"]

def _build_scripts_data(vary_by_target = False):
    return {
        "build_scripts": [
            {
                "target_triples": ["linux_target"],
                "crate_features": ["linux_feature"],
                "deps": ["@crates//:linux_helper"],
                "deps_by_platform": {},
                "aliases": {"@crates//:linux_helper": "helper"},
            },
            {
                "target_triples": ["macos_target"],
                "crate_features": ["macos_feature"],
                "deps": ["@crates//:macos_helper" if vary_by_target else "@crates//:linux_helper"],
                "deps_by_platform": {},
                "aliases": {"@crates//:macos_helper" if vary_by_target else "@crates//:linux_helper": "helper"},
            },
        ],
    }

def _all_crate_deps_invariant_scripts_ignore_own_features_impl(ctx):
    env = unittest.begin(ctx)
    data = _build_scripts_data()
    asserts.equals(env, ["@crates//:linux_helper"], all_crate_deps(data, ["//cfg:target"], build = True, build_platforms = _BUILD_PLATFORMS))
    asserts.equals(env, {"@crates//:linux_helper": "helper"}, crate_aliases(data, build = True))
    return unittest.end(env)

def _all_crate_deps_selects_execution_platform_impl(ctx):
    env = unittest.begin(ctx)
    data = _build_scripts_data()
    for script in data["build_scripts"]:
        script["deps"] = []
        script["deps_by_platform"] = {
            "//cfg:linux_exec": ["@crates//:linux_helper"],
            "//cfg:macos_exec": ["@crates//:macos_helper"],
        }
    deps = str(all_crate_deps(data, ["//cfg:target"], build = True, build_platforms = _BUILD_PLATFORMS))
    asserts.true(env, "//cfg:macos_exec" in deps)
    asserts.true(env, "//cfg:linux_exec" in deps)
    asserts.false(env, "//cfg:target" in deps)
    return unittest.end(env)

def _all_crate_deps_preserves_build_platform_domain_impl(ctx):
    env = unittest.begin(ctx)
    data = _build_scripts_data()
    data["deps_by_platform"] = {"//cfg:target": ["//:normal"]}
    deps = all_crate_deps(data, ["//cfg:target"], normal = True, build = True, build_platforms = _BUILD_PLATFORMS)
    asserts.equals(env, str([] + select({
        "//cfg:linux_exec": ["@crates//:linux_helper"],
        "//cfg:macos_exec": ["@crates//:linux_helper"],
        "//cfg:target": ["//:normal"],
        "//conditions:default": [],
    })), str(deps))

    for script in data["build_scripts"]:
        script["deps"] = []
    deps = all_crate_deps(data, ["//cfg:target"], normal = True, build = True, build_platforms = _BUILD_PLATFORMS)
    asserts.equals(env, str([] + select({
        "//cfg:target": ["//:normal"],
        "//conditions:default": [],
    })), str(deps))
    asserts.equals(env, ["//:normal"], all_crate_deps(data, ["//cfg:target"], normal = True, build = True))
    return unittest.end(env)

def _ambiguous_build_script_impl(ctx):
    data = _build_scripts_data(vary_by_target = ctx.attr.field != "deps_by_platform")
    if ctx.attr.field == "aliases":
        crate_aliases(data, build = True)
    else:
        if ctx.attr.field == "deps_by_platform":
            data["build_scripts"][1]["deps_by_platform"] = {"//cfg:macos_exec": ["@crates//:macos_helper"]}
        all_crate_deps(data, [], build = True)
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
all_crate_deps_invariant_scripts_ignore_own_features_test = unittest.make(_all_crate_deps_invariant_scripts_ignore_own_features_impl)
all_crate_deps_selects_execution_platform_test = unittest.make(_all_crate_deps_selects_execution_platform_impl)
all_crate_deps_preserves_build_platform_domain_test = unittest.make(_all_crate_deps_preserves_build_platform_domain_impl)

def all_crate_deps_tests():
    for field in ["aliases", "deps", "deps_by_platform"]:
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
        all_crate_deps_invariant_scripts_ignore_own_features_test,
        all_crate_deps_selects_execution_platform_test,
        all_crate_deps_preserves_build_platform_domain_test,
        partial.make(ambiguous_build_script_test, target_under_test = ":ambiguous_build_script_deps"),
        partial.make(ambiguous_build_script_test, target_under_test = ":ambiguous_build_script_deps_by_platform"),
        partial.make(ambiguous_build_script_test, target_under_test = ":ambiguous_build_script_aliases"),
    )
