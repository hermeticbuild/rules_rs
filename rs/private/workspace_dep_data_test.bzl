"""Tests for first-party target and build dependency labels."""

load("@bazel_skylib//lib:unittest.bzl", "asserts", "unittest")
load(":all_crate_deps.bzl", "all_crate_deps", "crate_aliases")
load(":cargo_workspace_graph.bzl", "workspace_dep_data")

def _workspace_aliases_select_dependency_kind_impl(ctx):
    env = unittest.begin(ctx)
    linux = "x86_64-unknown-linux-gnu"
    shared = "@crates//:shared-1.0.0"
    helper = "@crates//:local-helper-1.0.0"
    data = workspace_dep_data(
        cargo_metadata = {
            "packages": [{
                "name": "app",
                "version": "1.0.0",
                "manifest_path": "/workspace/Cargo.toml",
                "dependencies": [
                    {"name": "shared", "rename": "normal-shared", "kind": None, "bazel_target": "@crates//:shared-1.0.0"},
                    {"name": "shared", "rename": "build-shared", "kind": "build", "bazel_target": "@crates//:shared-1.0.0"},
                    {"name": "dev", "rename": "dev-dep", "kind": "dev", "bazel_target": "@crates//:dev-1.0.0"},
                    {"name": "local-helper", "kind": "build", "path": "/workspace/local-helper"},
                ],
            }, {
                "name": "local-helper",
                "version": "1.0.0",
                "manifest_path": "/workspace/local-helper/Cargo.toml",
                "dependencies": [],
            }],
        },
        dep_label_prefix = "@crates//:",
        platform_triples = [linux],
        platform_cfg_attrs = [],
        cfg_match_cache = {None: struct(matches = [linux], uses_feature_cfg = False)},
        repo_root = "/workspace",
        workspace_package = "",
        use_legacy_rules_rust_platforms = False,
        configurations_by_crate = {
            "app-1.0.0": struct(configurations = {"": {
                "crate_features_by_triple": {linux: []},
                "deps_by_triple": {linux: {shared: "normal_shared"}},
                "build_deps_by_triple": {linux: {linux: {shared: "build_shared", helper: None}}},
                "build_cargo_target_triple_required_on": [],
            }}),
            "local-helper-1.0.0": struct(configurations = {"": {
                "crate_features_by_triple": {linux: []},
                "deps_by_triple": {linux: {}},
                "build_deps_by_triple": {},
                "build_cargo_target_triple_required_on": [],
            }}),
        },
    )[""]
    expected = {
        "//local-helper": "local_helper",
        "@crates//:shared-1.0.0": "build_shared",
        "@crates//:dev-1.0.0": "dev_dep",
    }

    asserts.equals(env, {}, data.get("binaries"))
    asserts.equals(env, {}, data.get("shared_libraries"))
    asserts.equals(env, ["@crates//:shared-1.0.0"], all_crate_deps(data, hub_name = "crates"))
    asserts.equals(env, {"@crates//:shared-1.0.0": "normal_shared"}, crate_aliases(data, hub_name = "crates"))
    asserts.equals(env, expected, crate_aliases(data, normal = True, normal_dev = True, build = True, hub_name = "crates"))

    asserts.equals(env, ["//local-helper", "@crates//:shared-1.0.0"], all_crate_deps(data, build = True, hub_name = "crates"))
    asserts.equals(env, {
        "//local-helper": "local_helper",
        "@crates//:shared-1.0.0": "build_shared",
    }, crate_aliases(data, build = True, hub_name = "crates"))
    return unittest.end(env)

def _workspace_configurations_preserve_local_labels_impl(ctx):
    env = unittest.begin(ctx)
    linux = "x86_64-unknown-linux-gnu"
    macos = "aarch64-apple-darwin"
    helper = "@crates//:local-helper-1.0.0"
    external_helper = "@crates//:local-helper-2.0.0"
    shared = "@crates//:shared-1.0.0"
    optional = "@crates//:optional-1.0.0"
    normal = {
        "crate_features_by_triple": {linux: ["normal"]},
        "deps_by_triple": {linux: {helper: "renamed_helper", external_helper: "external_helper", shared: None}},
        "build_deps_by_triple": {linux: {linux: {}, macos: {helper: "build_helper", external_helper: "external_helper"}}},
        "build_cargo_target_triple_required_on": [],
    }
    execution = {
        "crate_features_by_triple": {macos: ["exec"]},
        "deps_by_triple": {macos: {helper: "renamed_helper", external_helper: "external_helper", optional: None}},
        "build_deps_by_triple": {macos: {macos: {}}},
        "build_cargo_target_triple_required_on": [],
    }
    data = workspace_dep_data(
        cargo_metadata = {"packages": [{
            "name": "app",
            "version": "1.0.0",
            "edition": "2021",
            "manifest_path": "/workspace/app/Cargo.toml",
            "targets": [
                {"name": "app-cli", "kind": ["bin"], "src_path": "/workspace/app/src/main.rs"},
                {"name": "app_native", "kind": ["cdylib"], "src_path": "/workspace/app/src/native.rs"},
            ],
            "dependencies": [
                {"name": "local-helper", "rename": "renamed-helper", "kind": None, "path": "/workspace/local-helper"},
                {"name": "local-helper", "rename": "build-helper", "kind": "build", "path": "/workspace/local-helper"},
                {"name": "local-helper", "rename": "external-helper", "kind": None, "path": "/workspace/excluded-helper", "bazel_target": external_helper},
                {"name": "local-helper", "rename": "external-helper", "kind": "build", "path": "/workspace/excluded-helper", "bazel_target": external_helper},
                {"name": "dev", "rename": "dev-dep", "kind": "dev", "bazel_target": "@crates//:dev-1.0.0"},
            ],
        }, {
            "name": "local-helper",
            "version": "1.0.0",
            "manifest_path": "/workspace/local-helper/Cargo.toml",
            "dependencies": [],
        }]},
        dep_label_prefix = "@crates//:",
        platform_triples = [linux],
        platform_cfg_attrs = [],
        cfg_match_cache = {None: struct(matches = [linux], uses_feature_cfg = False)},
        repo_root = "/workspace",
        workspace_package = "fixtures",
        use_legacy_rules_rust_platforms = False,
        lint_configs = {"fixtures/app": "@crates//:app_lints"},
        configurations_by_crate = {
            "app-1.0.0": struct(configurations = {"": normal, linux: execution, macos: execution}),
            "local-helper-1.0.0": struct(configurations = {"": {
                "crate_features_by_triple": {linux: [], macos: []},
                "deps_by_triple": {linux: {}, macos: {}},
                "build_deps_by_triple": {},
                "build_cargo_target_triple_required_on": [],
            }}),
        },
    )["fixtures/app"]
    local_helper = "//fixtures/local-helper"
    configured = data["configurations"]
    asserts.equals(env, {linux: {local_helper: "renamed_helper", external_helper: "external_helper", shared: None}}, configured[""]["deps_by_triple"])
    asserts.equals(env, {macos: {local_helper: "renamed_helper", external_helper: "external_helper", optional: None}}, configured[linux]["deps_by_triple"])
    asserts.equals(env, {linux: {linux: {}, macos: {local_helper: "build_helper", external_helper: "external_helper"}}}, configured[""]["build_deps_by_triple"])
    asserts.equals(env, configured[linux], configured[macos])
    asserts.equals(env, {"@crates//:dev-1.0.0": "dev_dep"}, data["dev_deps"])
    asserts.equals(env, {}, data["dev_deps_by_platform"])
    asserts.equals(env, ["@crates//:dev-1.0.0"], all_crate_deps(data, normal_dev = True, hub_name = "crates"))
    asserts.equals(env, {"@crates//:dev-1.0.0": "dev_dep"}, crate_aliases(data, normal_dev = True, hub_name = "crates"))
    asserts.equals(env, {"app-cli": "src/main.rs"}, data.get("binaries"))
    asserts.equals(env, {"app_native": "src/native.rs"}, data.get("shared_libraries"))
    asserts.equals(env, "2021", data["edition"])
    asserts.equals(env, "@crates//:app_lints", data["lint_config"])
    return unittest.end(env)

workspace_aliases_select_dependency_kind_test = unittest.make(_workspace_aliases_select_dependency_kind_impl)
workspace_configurations_preserve_local_labels_test = unittest.make(_workspace_configurations_preserve_local_labels_impl)

def workspace_dep_data_tests():
    return unittest.suite(
        "workspace_dep_data_tests",
        workspace_aliases_select_dependency_kind_test,
        workspace_configurations_preserve_local_labels_test,
    )
