"""Tests for first-party target and build dependency labels."""

load("@bazel_skylib//lib:unittest.bzl", "asserts", "unittest")
load(":all_crate_deps.bzl", "all_crate_deps", "crate_aliases")
load(":cargo_workspace_graph.bzl", "workspace_dep_data")

def _legacy_dep_data():
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
    )["app"]

def _workspace_aliases_default_preserves_all_kinds_impl(ctx):
    env = unittest.begin(ctx)
    data = _legacy_dep_data()
    expected = {
        "//local-helper": "local_helper",
        "@crates//:shared-1.0.0": "build_shared",
        "@crates//:dev-1.0.0": "dev_dep",
    }

    asserts.equals(env, expected, crate_aliases(data))
    asserts.equals(env, expected, crate_aliases(data, normal = True, normal_dev = True, build = True))
    asserts.equals(env, {"//:old": "old_alias"}, crate_aliases({"aliases": {"//:old": "old_alias"}}))
    return unittest.end(env)

def _workspace_legacy_build_deps_keep_labels_impl(ctx):
    env = unittest.begin(ctx)
    data = _legacy_dep_data()

    asserts.equals(env, ["//local-helper", "@crates//:shared-1.0.0"], all_crate_deps(data, [], build = True))
    asserts.equals(env, {
        "//local-helper": "local_helper",
        "@crates//:shared-1.0.0": "build_shared",
    }, crate_aliases(data, build = True))
    return unittest.end(env)

def _workspace_build_profiles_preserve_target_requirements_impl(ctx):
    env = unittest.begin(ctx)
    linux = "x86_64-unknown-linux-gnu"
    macos = "aarch64-apple-darwin"
    dep = "@crates//:helper-1.0.0"
    linux_dep = "@crates//:__exec/helper-1.0.0_exec_linux"
    macos_dep = "@crates//:__exec/helper-1.0.0_exec_macos"
    data = workspace_dep_data(
        cargo_metadata = {
            "packages": [{
                "name": "app",
                "version": "1.0.0",
                "manifest_path": "/workspace/app/Cargo.toml",
                "dependencies": [
                    {"name": "helper", "rename": "normal-helper", "kind": None, "bazel_target": dep},
                    {"name": "helper", "rename": "build-helper", "kind": "build", "bazel_target": dep},
                    {"name": "local-helper", "kind": "build", "path": "/workspace/local-helper"},
                    {"name": "dev", "rename": "dev-dep", "kind": "dev", "bazel_target": "@crates//:dev-1.0.0"},
                ],
            }],
        },
        feature_resolutions_by_fq_crate = {
            "app-1.0.0": struct(
                features_enabled = {
                    linux: set(["linux_feature", "dep:build-helper"]),
                    macos: set(["macos_feature"]),
                },
                possible_deps = [{"name": "local-helper", "kind": "build", "bazel_target": "@crates//:local-helper-1.0.0"}],
            ),
        },
        platform_triples = [linux, macos],
        platform_cfg_attrs = [],
        cfg_match_cache = {None: struct(matches = [linux, macos], uses_feature_cfg = False)},
        repo_root = "/workspace",
        workspace_package = "",
        use_legacy_rules_rust_platforms = False,
        target_build_deps = {
            linux: {"app-1.0.0": {
                linux: set([dep, "@crates//:local-helper-1.0.0"]),
                macos: set([dep, "@crates//:local-helper-1.0.0"]),
            }},
            macos: {"app-1.0.0": {linux: set(), macos: set([dep])}},
        },
        target_build_aliases = {
            linux: {"app-1.0.0": {dep: "build_helper"}},
            macos: {"app-1.0.0": {dep: "build_helper"}},
        },
        exec_labels_by_target = {
            linux: {dep: linux_dep},
            macos: {dep: macos_dep},
        },
    )["app"]

    asserts.equals(env, {
        linux: {
            "deps": {linux: ["//local-helper", linux_dep], macos: ["//local-helper", linux_dep]},
            "aliases": {linux_dep: "build_helper", "//local-helper": "local_helper"},
            "features": ["linux_feature"],
        },
        macos: {
            "deps": {linux: [], macos: [macos_dep]},
            "aliases": {macos_dep: "build_helper"},
            "features": ["macos_feature"],
        },
    }, data["build_script_profiles"])
    asserts.equals(env, {
        linux: "@rules_rs//rs/platforms/config:" + linux,
        macos: "@rules_rs//rs/platforms/config:" + macos,
    }, data["build_script_platforms"])
    asserts.equals(env, [dep], all_crate_deps(data, [], normal = True))
    asserts.equals(env, ["@crates//:dev-1.0.0"], all_crate_deps(data, [], normal_dev = True))
    asserts.equals(env, {"@crates//:dev-1.0.0": "dev_dep"}, crate_aliases(data, normal_dev = True))
    asserts.equals(env, {dep: "normal_helper"}, crate_aliases(data, normal = True))
    asserts.equals(env, {
        dep: "normal_helper",
        linux_dep: "build_helper",
        macos_dep: "build_helper",
        "//local-helper": "local_helper",
        "@crates//:dev-1.0.0": "dev_dep",
    }, crate_aliases(data))
    asserts.false(env, "build_deps" in data)
    return unittest.end(env)

def _workspace_build_profiles_preserve_empty_targets_impl(ctx):
    env = unittest.begin(ctx)
    data = workspace_dep_data(
        cargo_metadata = {"packages": [{
            "name": "app",
            "version": "1.0.0",
            "manifest_path": "/workspace/Cargo.toml",
            "dependencies": [],
        }]},
        feature_resolutions_by_fq_crate = {},
        platform_triples = ["x86_64-unknown-linux-gnu"],
        platform_cfg_attrs = [],
        cfg_match_cache = {},
        repo_root = "/workspace",
        workspace_package = "",
        use_legacy_rules_rust_platforms = False,
        target_build_deps = {},
    )[""]
    asserts.equals(env, {
        "x86_64-unknown-linux-gnu": {"deps": {}, "aliases": {}, "features": []},
    }, data["build_script_profiles"])
    asserts.equals(env, [], all_crate_deps(data, [], build = True))
    return unittest.end(env)

workspace_aliases_default_preserves_all_kinds_test = unittest.make(_workspace_aliases_default_preserves_all_kinds_impl)
workspace_legacy_build_deps_keep_labels_test = unittest.make(_workspace_legacy_build_deps_keep_labels_impl)
workspace_build_profiles_preserve_target_requirements_test = unittest.make(_workspace_build_profiles_preserve_target_requirements_impl)
workspace_build_profiles_preserve_empty_targets_test = unittest.make(_workspace_build_profiles_preserve_empty_targets_impl)

def workspace_dep_data_tests():
    return unittest.suite(
        "workspace_dep_data_tests",
        workspace_aliases_default_preserves_all_kinds_test,
        workspace_legacy_build_deps_keep_labels_test,
        workspace_build_profiles_preserve_target_requirements_test,
        workspace_build_profiles_preserve_empty_targets_test,
    )
