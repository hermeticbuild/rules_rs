load("@bazel_skylib//lib:unittest.bzl", "asserts", "unittest")
load("@workspace_default_features//:defs.bzl", cargo_deps = "all_crate_deps")
load("@workspace_hyphen_dep_aliases//:defs.bzl", workspace_deps = "all_crate_deps")

def _cargo_prefix_impl(ctx):
    env = unittest.begin(ctx)
    dep = "@workspace_default_features//:itoa-1.0.17"
    for cargo_only in [False, True]:
        for prefix in [None, "", "@", "@workspace_default_features//:", "@workspace_default_features//:itoa-", dep]:
            asserts.equals(env, [dep], cargo_deps(
                package_name = "workspace_default_features/app",
                cargo_only = cargo_only,
                filter_prefix = prefix,
            ))
        for prefix in ["//", "@other//:", "@workspace_default_features//:missing"]:
            asserts.equals(env, [], cargo_deps(
                package_name = "workspace_default_features/app",
                cargo_only = cargo_only,
                filter_prefix = prefix,
            ))
    return unittest.end(env)

def _workspace_prefix_impl(ctx):
    env = unittest.begin(ctx)
    dep = "//workspace_hyphen_dep_aliases/dep-crate"
    for prefix in [None, "", "//", "//workspace_hyphen_dep_aliases/", dep]:
        asserts.equals(env, [dep], workspace_deps(
            package_name = "workspace_hyphen_dep_aliases/consumer",
            filter_prefix = prefix,
        ))
        asserts.equals(env, [], workspace_deps(
            package_name = "workspace_hyphen_dep_aliases/consumer",
            cargo_only = True,
            filter_prefix = prefix,
        ))
    return unittest.end(env)

cargo_prefix_test = unittest.make(_cargo_prefix_impl)
workspace_prefix_test = unittest.make(_workspace_prefix_impl)

def all_crate_deps_tests():
    unittest.suite(
        "all_crate_deps_tests",
        cargo_prefix_test,
        workspace_prefix_test,
    )
