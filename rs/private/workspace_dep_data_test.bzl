"""Tests for first-party target and build dependency labels."""

load("@bazel_skylib//lib:unittest.bzl", "asserts", "unittest")
load(":all_crate_deps.bzl", "all_crate_deps", "crate_aliases")
load(":cargo_workspace_graph.bzl", "workspace_dep_data")

def _dep_data(exec_labels):
    linux = "x86_64-unknown-linux-gnu"
    return workspace_dep_data(
        cargo_metadata = {
            "packages": [{
                "name": "app",
                "version": "1.0.0",
                "manifest_path": "/workspace/app/Cargo.toml",
                "dependencies": [
                    {"name": "shared", "rename": "normal-shared", "kind": None, "bazel_target": "@crates//:shared-1.0.0"},
                    {"name": "shared", "rename": "build-shared", "kind": "build", "bazel_target": "@crates//:shared-1.0.0"},
                    {"name": "dev", "rename": "dev-dep", "kind": "dev", "bazel_target": "@crates//:dev-1.0.0"},
                    {"name": "local-helper", "kind": "build", "path": "/workspace/local-helper"},
                ],
            }],
        },
        feature_resolutions_by_fq_crate = {},
        platform_triples = [linux],
        platform_cfg_attrs = [],
        cfg_match_cache = {None: struct(matches = [linux], uses_feature_cfg = False)},
        repo_root = "/workspace",
        workspace_package = "",
        use_legacy_rules_rust_platforms = False,
        exec_labels = exec_labels,
    )["app"]

def _workspace_build_deps_use_exec_labels_impl(ctx):
    env = unittest.begin(ctx)
    data = _dep_data({
        "@crates//:shared-1.0.0": "@crates//:__exec/shared-1.0.0",
        "@crates//:dev-1.0.0": "@crates//:__exec/dev-1.0.0",
    })

    asserts.equals(env, ["@crates//:shared-1.0.0"], all_crate_deps(data, [], normal = True))
    asserts.equals(env, ["@crates//:dev-1.0.0"], all_crate_deps(data, [], normal_dev = True))
    asserts.equals(env, ["//local-helper", "@crates//:__exec/shared-1.0.0"], all_crate_deps(data, [], build = True))
    asserts.equals(env, {"@crates//:shared-1.0.0": "normal_shared"}, crate_aliases(data, normal = True))
    asserts.equals(env, {"@crates//:dev-1.0.0": "dev_dep"}, crate_aliases(data, normal_dev = True))
    asserts.equals(env, {
        "//local-helper": "local_helper",
        "@crates//:__exec/shared-1.0.0": "build_shared",
    }, crate_aliases(data, build = True))
    return unittest.end(env)

def _workspace_aliases_default_preserves_all_kinds_impl(ctx):
    env = unittest.begin(ctx)
    data = _dep_data({"@crates//:shared-1.0.0": "@crates//:__exec/shared-1.0.0"})
    expected = {
        "//local-helper": "local_helper",
        "@crates//:shared-1.0.0": "normal_shared",
        "@crates//:__exec/shared-1.0.0": "build_shared",
        "@crates//:dev-1.0.0": "dev_dep",
    }

    asserts.equals(env, expected, crate_aliases(data))
    asserts.equals(env, expected, crate_aliases(data, normal = True, normal_dev = True, build = True))
    asserts.equals(env, {"//:old": "old_alias"}, crate_aliases({"aliases": {"//:old": "old_alias"}}))
    return unittest.end(env)

def _workspace_unsplit_build_deps_keep_labels_impl(ctx):
    env = unittest.begin(ctx)
    data = _dep_data({})

    asserts.equals(env, ["//local-helper", "@crates//:shared-1.0.0"], all_crate_deps(data, [], build = True))
    asserts.equals(env, {
        "//local-helper": "local_helper",
        "@crates//:shared-1.0.0": "build_shared",
    }, crate_aliases(data, build = True))
    return unittest.end(env)

workspace_build_deps_use_exec_labels_test = unittest.make(_workspace_build_deps_use_exec_labels_impl)
workspace_aliases_default_preserves_all_kinds_test = unittest.make(_workspace_aliases_default_preserves_all_kinds_impl)
workspace_unsplit_build_deps_keep_labels_test = unittest.make(_workspace_unsplit_build_deps_keep_labels_impl)

def workspace_dep_data_tests():
    return unittest.suite(
        "workspace_dep_data_tests",
        workspace_build_deps_use_exec_labels_test,
        workspace_aliases_default_preserves_all_kinds_test,
        workspace_unsplit_build_deps_keep_labels_test,
    )
