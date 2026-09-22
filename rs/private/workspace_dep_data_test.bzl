"""Tests for first-party target and build dependency labels."""

load("@bazel_skylib//lib:unittest.bzl", "asserts", "unittest")
load(":all_crate_deps.bzl", "all_crate_deps", "crate_aliases")
load(":cargo_workspace_graph.bzl", "workspace_dep_data")

def _configured_dep_data():
    linux = "x86_64-unknown-linux-gnu"
    shared = "@crates//:shared-1.0.0"
    helper = "@crates//:local-helper-1.0.0"
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
    )["app"]

def _workspace_aliases_select_dependency_kind_impl(ctx):
    env = unittest.begin(ctx)
    data = _configured_dep_data()
    expected = {
        "//local-helper": "local_helper",
        "@crates//:shared-1.0.0": "build_shared",
        "@crates//:dev-1.0.0": "dev_dep",
    }

    asserts.equals(env, {"@crates//:shared-1.0.0": "normal_shared"}, crate_aliases(data, hub_name = "crates"))
    asserts.equals(env, expected, crate_aliases(data, normal = True, normal_dev = True, build = True, hub_name = "crates"))
    return unittest.end(env)

def _workspace_build_deps_keep_labels_impl(ctx):
    env = unittest.begin(ctx)
    data = _configured_dep_data()

    asserts.equals(env, ["//local-helper", "@crates//:shared-1.0.0"], all_crate_deps(data, build = True, hub_name = "crates"))
    asserts.equals(env, {
        "//local-helper": "local_helper",
        "@crates//:shared-1.0.0": "build_shared",
    }, crate_aliases(data, build = True, hub_name = "crates"))
    return unittest.end(env)

def _workspace_configurations_preserve_target_requirements_impl(ctx):
    env = unittest.begin(ctx)
    linux = "x86_64-unknown-linux-gnu"
    macos = "aarch64-apple-darwin"
    dep = "@crates//:helper-1.0.0"
    local_helper = "@crates//:local-helper-1.0.0"
    configuration = {
        "crate_features_by_triple": {linux: ["common_feature", "linux_feature"], macos: ["common_feature", "macos_feature"]},
        "deps_by_triple": {linux: {dep: "normal_helper"}, macos: {dep: "normal_helper"}},
        "build_deps_by_triple": {
            linux: {linux: {dep: "build_helper", local_helper: None}, macos: {dep: "build_helper", local_helper: None}},
            macos: {linux: {}, macos: {dep: "build_helper"}},
        },
        "build_cargo_target_triple_required_on": [],
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
        }, {
            "name": "local-helper",
            "version": "1.0.0",
            "manifest_path": "/workspace/local-helper/Cargo.toml",
            "dependencies": [],
        }]},
        dep_label_prefix = "@crates//:",
        platform_triples = [linux, macos],
        platform_cfg_attrs = [],
        cfg_match_cache = {None: struct(matches = [linux, macos], uses_feature_cfg = False)},
        repo_root = "/workspace",
        workspace_package = "",
        use_legacy_rules_rust_platforms = False,
        configurations_by_crate = {
            "app-1.0.0": struct(configurations = {"": configuration}),
            "local-helper-1.0.0": struct(configurations = {"": {
                "crate_features_by_triple": {linux: [], macos: []},
                "deps_by_triple": {linux: {}, macos: {}},
                "build_deps_by_triple": {},
                "build_cargo_target_triple_required_on": [],
            }}),
        },
    )["app"]
    configured = data["configurations"][""]
    asserts.equals(env, configuration["crate_features_by_triple"], configured["crate_features_by_triple"])
    asserts.equals(env, {
        linux: {linux: {dep: "build_helper", "//local-helper": "local_helper"}, macos: {dep: "build_helper", "//local-helper": "local_helper"}},
        macos: {linux: {}, macos: {dep: "build_helper"}},
    }, configured["build_deps_by_triple"])
    asserts.equals(env, [dep], all_crate_deps(data, normal = True, hub_name = "crates"))
    asserts.equals(env, ["@crates//:dev-1.0.0"], all_crate_deps(data, normal_dev = True, hub_name = "crates"))
    asserts.equals(env, {"@crates//:dev-1.0.0": "dev_dep"}, crate_aliases(data, normal_dev = True, hub_name = "crates"))
    asserts.equals(env, {dep: "normal_helper"}, crate_aliases(data, normal = True, hub_name = "crates"))
    for field in ["aliases", "normal_aliases", "deps", "deps_by_platform", "crate_features", "crate_features_by_platform", "build_deps", "build_scripts", "binaries", "shared_libraries"]:
        asserts.false(env, field in data)
    return unittest.end(env)

def _workspace_configurations_preserve_empty_targets_impl(ctx):
    env = unittest.begin(ctx)
    linux = "x86_64-unknown-linux-gnu"
    macos = "aarch64-apple-darwin"
    configuration = {
        "crate_features_by_triple": {linux: [], macos: []},
        "deps_by_triple": {linux: {}, macos: {}},
        "build_deps_by_triple": {platform_triple: {linux: {}, macos: {}} for platform_triple in [linux, macos]},
        "build_cargo_target_triple_required_on": [],
    }
    data = workspace_dep_data(
        cargo_metadata = {"packages": [{
            "name": "app",
            "version": "1.0.0",
            "manifest_path": "/workspace/Cargo.toml",
            "dependencies": [],
        }]},
        dep_label_prefix = "@crates//:",
        platform_triples = [linux, macos],
        platform_cfg_attrs = [],
        cfg_match_cache = {},
        repo_root = "/workspace",
        workspace_package = "",
        use_legacy_rules_rust_platforms = False,
        configurations_by_crate = {"app-1.0.0": struct(configurations = {"": configuration})},
    )[""]
    asserts.equals(env, configuration, data["configurations"][""])
    asserts.equals(env, [], all_crate_deps(data, build = True, hub_name = "crates"))
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
        "build_deps_by_triple": {linux: {macos: {helper: "build_helper", external_helper: "external_helper"}}},
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
    asserts.equals(env, {linux: {macos: {local_helper: "build_helper", external_helper: "external_helper"}}}, configured[""]["build_deps_by_triple"])
    asserts.equals(env, configured[linux], configured[macos])
    asserts.equals(env, {"@crates//:dev-1.0.0": "dev_dep"}, data["dev_deps"])
    asserts.equals(env, "2021", data["edition"])
    asserts.equals(env, "@crates//:app_lints", data["lint_config"])
    return unittest.end(env)

def _workspace_optional_aliases_keep_selected_name_impl(ctx):
    env = unittest.begin(ctx)
    linux = "x86_64-unknown-linux-gnu"
    helper = "@crates//:helper-1.0.0"
    for selected in ["first-name", "second-name"]:
        expected = {helper: selected.replace("-", "_")}
        configuration = {
            "crate_features_by_triple": {linux: ["dep:" + selected]},
            "deps_by_triple": {linux: expected},
            "build_deps_by_triple": {linux: {linux: expected}},
            "build_cargo_target_triple_required_on": [],
        }
        data = workspace_dep_data(
            cargo_metadata = {"packages": [{
                "name": "app",
                "version": "1.0.0",
                "manifest_path": "/workspace/Cargo.toml",
                "dependencies": [{
                    "name": "helper",
                    "rename": name,
                    "kind": kind,
                    "optional": True,
                    "bazel_target": helper,
                } for kind in [None, "build"] for name in ["first-name", "second-name"]],
            }]},
            dep_label_prefix = "@crates//:",
            platform_triples = [linux],
            platform_cfg_attrs = [],
            cfg_match_cache = {},
            repo_root = "/workspace",
            workspace_package = "",
            use_legacy_rules_rust_platforms = False,
            configurations_by_crate = {"app-1.0.0": struct(configurations = {"": configuration})},
        )[""]
        asserts.equals(env, expected, crate_aliases(data, normal = True, hub_name = "crates"))
        asserts.equals(env, expected, crate_aliases(data, build = True, hub_name = "crates"))
    return unittest.end(env)

def _workspace_common_dev_dependencies_apply_to_execution_platform_impl(ctx):
    env = unittest.begin(ctx)
    linux = "x86_64-unknown-linux-gnu"
    macos = "aarch64-apple-darwin"
    dev = "@crates//:dev-1.0.0"
    data = workspace_dep_data(
        cargo_metadata = {"packages": [{
            "name": "app",
            "version": "1.0.0",
            "manifest_path": "/workspace/Cargo.toml",
            "dependencies": [{"name": "dev", "rename": "selected-dev", "kind": "dev", "bazel_target": dev}],
        }]},
        dep_label_prefix = "@crates//:",
        platform_triples = [linux],
        platform_cfg_attrs = [],
        cfg_match_cache = {None: struct(matches = [linux], uses_feature_cfg = False)},
        repo_root = "/workspace",
        workspace_package = "",
        use_legacy_rules_rust_platforms = False,
        configurations_by_crate = {"app-1.0.0": struct(configurations = {
            cargo_target_triple: {
                "crate_features_by_triple": {platform_triple: []},
                "deps_by_triple": {platform_triple: {}},
                "build_deps_by_triple": {},
                "build_cargo_target_triple_required_on": [],
            }
            for cargo_target_triple, platform_triple in [("", linux), (linux, macos)]
        })},
    )[""]

    asserts.equals(env, {dev: "selected_dev"}, data["dev_deps"])
    asserts.equals(env, {}, data["dev_deps_by_platform"])
    asserts.false(env, "dev_aliases" in data)
    asserts.equals(env, [dev], all_crate_deps(data, normal_dev = True, hub_name = "crates"))
    asserts.equals(env, {dev: "selected_dev"}, crate_aliases(data, normal_dev = True, hub_name = "crates"))
    return unittest.end(env)

workspace_aliases_select_dependency_kind_test = unittest.make(_workspace_aliases_select_dependency_kind_impl)
workspace_build_deps_keep_labels_test = unittest.make(_workspace_build_deps_keep_labels_impl)
workspace_configurations_preserve_target_requirements_test = unittest.make(_workspace_configurations_preserve_target_requirements_impl)
workspace_configurations_preserve_empty_targets_test = unittest.make(_workspace_configurations_preserve_empty_targets_impl)
workspace_configurations_preserve_local_labels_test = unittest.make(_workspace_configurations_preserve_local_labels_impl)
workspace_optional_aliases_keep_selected_name_test = unittest.make(_workspace_optional_aliases_keep_selected_name_impl)
workspace_common_dev_dependencies_apply_to_execution_platform_test = unittest.make(_workspace_common_dev_dependencies_apply_to_execution_platform_impl)

def workspace_dep_data_tests():
    return unittest.suite(
        "workspace_dep_data_tests",
        workspace_aliases_select_dependency_kind_test,
        workspace_build_deps_keep_labels_test,
        workspace_configurations_preserve_target_requirements_test,
        workspace_configurations_preserve_empty_targets_test,
        workspace_configurations_preserve_local_labels_test,
        workspace_optional_aliases_keep_selected_name_test,
        workspace_common_dev_dependencies_apply_to_execution_platform_test,
    )
