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

def _workspace_configurations_preserve_target_requirements_impl(ctx):
    env = unittest.begin(ctx)
    linux = "x86_64-unknown-linux-gnu"
    macos = "aarch64-apple-darwin"
    dep = "@crates//:helper-1.0.0"
    local_helper = "@crates//:local-helper-1.0.0"
    definition = {
        "crate_features_select": {linux: ["common_feature", "linux_feature"], macos: ["common_feature", "macos_feature"]},
        "deps_select": {linux: [dep], macos: [dep]},
        "aliases": {dep: "normal_helper"},
        "build_deps_by_target": {
            linux: {linux: [dep, local_helper], macos: [dep, local_helper]},
            macos: {linux: [], macos: [dep]},
        },
        "build_aliases_by_target": {linux: {dep: "build_helper"}, macos: {dep: "build_helper"}},
    }
    data = workspace_dep_data(
        cargo_metadata = {"packages": [{
            "name": "app",
            "version": "1.0.0",
            "manifest_path": "/workspace/app/Cargo.toml",
            "dependencies": [
                {"name": "helper", "rename": "normal-helper", "kind": None, "bazel_target": dep},
                {"name": "helper", "rename": "build-helper", "kind": "build", "bazel_target": dep},
                {"name": "local-helper", "kind": "build", "path": "/workspace/local-helper"},
                {"name": "dev", "rename": "dev-dep", "kind": "dev", "bazel_target": "@crates//:dev-1.0.0"},
            ],
        }]},
        feature_resolutions_by_fq_crate = {"app-1.0.0": struct(
            features_enabled = {
                linux: set(["common_feature", "linux_feature", "dep:build-helper"]),
                macos: set(["common_feature", "macos_feature"]),
            },
            possible_deps = [{"name": "local-helper", "kind": "build", "bazel_target": local_helper}],
        )},
        platform_triples = [linux, macos],
        platform_cfg_attrs = [],
        cfg_match_cache = {None: struct(matches = [linux, macos], uses_feature_cfg = False)},
        repo_root = "/workspace",
        workspace_package = "",
        use_legacy_rules_rust_platforms = False,
        configurations_by_crate = {"app-1.0.0": {"context_map": {"": ""}, "definitions": {"": definition}}},
    )["app"]
    configured = data["configurations"][""]
    asserts.equals(env, definition["crate_features_select"], configured["crate_features_select"])
    asserts.equals(env, {
        linux: {linux: [dep, "//local-helper"], macos: [dep, "//local-helper"]},
        macos: {linux: [], macos: [dep]},
    }, configured["build_deps_by_target"])
    asserts.equals(env, {
        linux: {dep: "build_helper", "//local-helper": "local_helper"},
        macos: {dep: "build_helper"},
    }, configured["build_aliases_by_target"])
    asserts.equals(env, ["common_feature"], data["crate_features"])
    asserts.equals(env, [dep], all_crate_deps(data, [], normal = True, hub_name = "crates"))
    asserts.equals(env, ["@crates//:dev-1.0.0"], all_crate_deps(data, [], normal_dev = True, hub_name = "crates"))
    asserts.equals(env, {"@crates//:dev-1.0.0": "dev_dep"}, crate_aliases(data, normal_dev = True, hub_name = "crates"))
    asserts.equals(env, {dep: "normal_helper"}, crate_aliases(data, normal = True, hub_name = "crates"))
    asserts.equals(env, {dep: "build_helper", "//local-helper": "local_helper", "@crates//:dev-1.0.0": "dev_dep"}, data["aliases"])
    asserts.false(env, "build_deps" in data)
    asserts.false(env, "build_scripts" in data)
    return unittest.end(env)

def _workspace_configurations_preserve_empty_targets_impl(ctx):
    env = unittest.begin(ctx)
    linux = "x86_64-unknown-linux-gnu"
    macos = "aarch64-apple-darwin"
    definition = {
        "crate_features_select": {linux: [], macos: []},
        "deps_select": {linux: [], macos: []},
        "aliases": {},
        "build_deps_by_target": {triple: {linux: [], macos: []} for triple in [linux, macos]},
        "build_aliases_by_target": {linux: {}, macos: {}},
        "build_contexts": {linux: "", macos: ""},
    }
    data = workspace_dep_data(
        cargo_metadata = {"packages": [{
            "name": "app",
            "version": "1.0.0",
            "manifest_path": "/workspace/Cargo.toml",
            "dependencies": [],
        }]},
        feature_resolutions_by_fq_crate = {},
        platform_triples = [linux, macos],
        platform_cfg_attrs = [],
        cfg_match_cache = {},
        repo_root = "/workspace",
        workspace_package = "",
        use_legacy_rules_rust_platforms = False,
        configurations_by_crate = {"app-1.0.0": {"context_map": {"": ""}, "definitions": {"": definition}}},
    )[""]
    asserts.equals(env, definition, data["configurations"][""])
    asserts.equals(env, [], all_crate_deps(data, [], build = True, hub_name = "crates"))
    return unittest.end(env)

def _workspace_configurations_preserve_local_labels_impl(ctx):
    env = unittest.begin(ctx)
    linux = "x86_64-unknown-linux-gnu"
    macos = "aarch64-apple-darwin"
    helper = "@crates//:local-helper-1.0.0"
    shared = "@crates//:shared-1.0.0"
    optional = "@crates//:optional-1.0.0"
    normal = {
        "crate_features_select": {linux: ["normal"]},
        "deps_select": {linux: [helper, shared]},
        "aliases": {helper: "local_helper"},
        "build_deps_by_target": {linux: {macos: [helper]}},
        "build_aliases_by_target": {linux: {helper: "local_helper"}},
    }
    execution = {
        "crate_features_select": {macos: ["exec"]},
        "deps_select": {macos: [helper, optional]},
        "aliases": {helper: "local_helper"},
        "build_deps_by_target": {macos: {macos: []}},
        "build_aliases_by_target": {macos: {}},
    }
    data = workspace_dep_data(
        cargo_metadata = {"packages": [{
            "name": "app",
            "version": "1.0.0",
            "edition": "2021",
            "manifest_path": "/workspace/app/Cargo.toml",
            "dependencies": [
                {"name": "local-helper", "rename": "renamed-helper", "kind": None, "path": "/workspace/local-helper"},
                {"name": "local-helper", "rename": "build-helper", "kind": "build", "path": "/workspace/local-helper"},
                {"name": "dev", "rename": "dev-dep", "kind": "dev", "bazel_target": "@crates//:dev-1.0.0"},
            ],
            "targets": [{"name": "app", "kind": ["bin"], "src_path": "/workspace/app/src/main.rs"}],
        }]},
        feature_resolutions_by_fq_crate = {"app-1.0.0": struct(
            features_enabled = {linux: set(["normal"])},
            possible_deps = [
                {"name": "renamed-helper", "bazel_target": helper},
                {"name": "build-helper", "kind": "build", "bazel_target": helper},
            ],
        )},
        platform_triples = [linux],
        platform_cfg_attrs = [],
        cfg_match_cache = {None: struct(matches = [linux], uses_feature_cfg = False)},
        repo_root = "/workspace",
        workspace_package = "fixtures",
        use_legacy_rules_rust_platforms = False,
        lint_configs = {"fixtures/app": "@crates//:app_lints"},
        configurations_by_crate = {"app-1.0.0": {
            "context_map": {"": "", linux: linux, macos: linux},
            "definitions": {"": normal, linux: execution},
        }},
    )["fixtures/app"]
    local_helper = "//fixtures/local-helper"
    configured = data["configurations"]
    asserts.equals(env, {linux: [local_helper, shared]}, configured[""]["deps_select"])
    asserts.equals(env, {macos: [local_helper, optional]}, configured[linux]["deps_select"])
    asserts.equals(env, {local_helper: "renamed_helper"}, configured[""]["aliases"])
    asserts.equals(env, {local_helper: "renamed_helper"}, configured[linux]["aliases"])
    asserts.equals(env, {linux: {macos: [local_helper]}}, configured[""]["build_deps_by_target"])
    asserts.equals(env, {linux: {local_helper: "build_helper"}}, configured[""]["build_aliases_by_target"])
    asserts.equals(env, configured[linux], configured[macos])
    asserts.equals(env, ["@crates//:dev-1.0.0"], data["dev_deps"])
    asserts.equals(env, {"app": "src/main.rs"}, data["binaries"])
    asserts.equals(env, "2021", data["edition"])
    asserts.equals(env, "@crates//:app_lints", data["lint_config"])
    return unittest.end(env)

workspace_aliases_default_preserves_all_kinds_test = unittest.make(_workspace_aliases_default_preserves_all_kinds_impl)
workspace_legacy_build_deps_keep_labels_test = unittest.make(_workspace_legacy_build_deps_keep_labels_impl)
workspace_configurations_preserve_target_requirements_test = unittest.make(_workspace_configurations_preserve_target_requirements_impl)
workspace_configurations_preserve_empty_targets_test = unittest.make(_workspace_configurations_preserve_empty_targets_impl)
workspace_configurations_preserve_local_labels_test = unittest.make(_workspace_configurations_preserve_local_labels_impl)

def workspace_dep_data_tests():
    return unittest.suite(
        "workspace_dep_data_tests",
        workspace_aliases_default_preserves_all_kinds_test,
        workspace_legacy_build_deps_keep_labels_test,
        workspace_configurations_preserve_target_requirements_test,
        workspace_configurations_preserve_empty_targets_test,
        workspace_configurations_preserve_local_labels_test,
    )
