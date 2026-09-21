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

def _build_profiles_data(vary_by_target = False):
    return {
        "build_script_profiles": {
            "linux_target": {
                "deps": {"macos_exec": ["@crates//:linux_helper"], "linux_exec": ["@crates//:linux_helper"]},
                "aliases": {"@crates//:linux_helper": "helper"},
                "features": ["linux_feature"],
            },
            "macos_target": {
                "deps": {
                    "macos_exec": ["@crates//:macos_helper" if vary_by_target else "@crates//:linux_helper"],
                    "linux_exec": ["@crates//:macos_helper" if vary_by_target else "@crates//:linux_helper"],
                },
                "aliases": {"@crates//:macos_helper" if vary_by_target else "@crates//:linux_helper": "helper"},
                "features": ["macos_feature"],
            },
        },
        "build_script_platforms": {"macos_exec": "//cfg:macos_exec", "linux_exec": "//cfg:linux_exec"},
    }

def _all_crate_deps_invariant_profiles_ignore_own_features_impl(ctx):
    env = unittest.begin(ctx)
    data = _build_profiles_data()
    asserts.equals(env, ["@crates//:linux_helper"], all_crate_deps(data, ["//cfg:target"], build = True))
    asserts.equals(env, {"@crates//:linux_helper": "helper"}, crate_aliases(data, build = True))
    return unittest.end(env)

def _all_crate_deps_selects_execution_platform_impl(ctx):
    env = unittest.begin(ctx)
    data = _build_profiles_data()
    for profile in data["build_script_profiles"].values():
        profile["deps"]["macos_exec"] = ["@crates//:macos_helper"]
    deps = str(all_crate_deps(data, ["//cfg:target"], build = True))
    asserts.true(env, "//cfg:macos_exec" in deps)
    asserts.true(env, "//cfg:linux_exec" in deps)
    asserts.false(env, "//cfg:target" in deps)
    return unittest.end(env)

def _ambiguous_build_profile_impl(ctx):
    data = _build_profiles_data(vary_by_target = True)
    if ctx.attr.aliases:
        crate_aliases(data, build = True)
    else:
        all_crate_deps(data, [], build = True)
    return []

_ambiguous_build_profile = rule(
    implementation = _ambiguous_build_profile_impl,
    attrs = {"aliases": attr.bool()},
)

def _ambiguous_build_profile_test_impl(ctx):
    env = analysistest.begin(ctx)
    asserts.expect_failure(env, "Use cargo_build_script from the generated Cargo repository's defs.bzl.")
    return analysistest.end(env)

ambiguous_build_profile_test = analysistest.make(_ambiguous_build_profile_test_impl, expect_failure = True)

merge_structured_dep_specs_dedupes_and_promotes_test = unittest.make(_merge_structured_dep_specs_dedupes_and_promotes_impl)
merge_structured_dep_specs_applies_filter_prefix_test = unittest.make(_merge_structured_dep_specs_applies_filter_prefix_impl)
all_crate_deps_defaults_to_normal_test = unittest.make(_all_crate_deps_defaults_to_normal_impl)
all_crate_deps_dedupes_across_selected_kinds_test = unittest.make(_all_crate_deps_dedupes_across_selected_kinds_impl)
all_crate_deps_invariant_profiles_ignore_own_features_test = unittest.make(_all_crate_deps_invariant_profiles_ignore_own_features_impl)
all_crate_deps_selects_execution_platform_test = unittest.make(_all_crate_deps_selects_execution_platform_impl)

def all_crate_deps_tests():
    for aliases in [False, True]:
        _ambiguous_build_profile(
            name = "ambiguous_build_profile_aliases" if aliases else "ambiguous_build_profile_deps",
            aliases = aliases,
            tags = ["manual"],
        )
    return unittest.suite(
        "all_crate_deps_tests",
        merge_structured_dep_specs_dedupes_and_promotes_test,
        merge_structured_dep_specs_applies_filter_prefix_test,
        all_crate_deps_defaults_to_normal_test,
        all_crate_deps_dedupes_across_selected_kinds_test,
        all_crate_deps_invariant_profiles_ignore_own_features_test,
        all_crate_deps_selects_execution_platform_test,
        partial.make(ambiguous_build_profile_test, target_under_test = ":ambiguous_build_profile_deps"),
        partial.make(ambiguous_build_profile_test, target_under_test = ":ambiguous_build_profile_aliases"),
    )
