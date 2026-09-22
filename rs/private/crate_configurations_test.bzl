"""Tests for Cargo configuration equivalence and dependency identity."""

load("@bazel_skylib//lib:unittest.bzl", "asserts", "unittest")
load(":crate_configurations.bzl", "prepare_crate_configurations")

_LINUX = "x86_64-unknown-linux-gnu"
_MACOS = "aarch64-apple-darwin"
_PREFIX = "@crates//:"

def _resolution(features = None, deps = None, build_deps = None, aliases = {}, active = True):
    features = features if features != None else {_LINUX: []}
    return struct(
        active = set(features) if active else set(),
        features_enabled = {triple: set(values) for triple, values in features.items()},
        deps = {triple: set(values) for triple, values in (deps or {triple: [] for triple in features}).items()},
        build_deps = {triple: set(values) for triple, values in (build_deps or {triple: [] for triple in features}).items()},
        aliases = aliases,
    )

def _prepare(target, execution, build_deps = {}, build_aliases = {}, **kwargs):
    return prepare_crate_configurations(target, execution, build_deps, build_aliases, _PREFIX, **kwargs)

def _definition(result, fq, context = ""):
    crate = result[fq]
    return crate["definitions"][crate["context_map"][context]]

def _assert_context_maps(env, result):
    asserts.equals(env, result, json.decode(json.encode(result)))
    for crate in result.values():
        for representative in crate["context_map"].values():
            asserts.equals(env, representative, crate["context_map"][representative])
            asserts.true(env, representative in crate["definitions"])

def _matching_definitions_impl(ctx):
    env = unittest.begin(ctx)
    target = {"shared-1.0.0": _resolution(features = {_LINUX: ["std", "dep:optional"]})}
    execution = {"shared-1.0.0": _resolution(features = {_LINUX: ["std"]})}
    result = _prepare(target, {_LINUX: execution, _MACOS: execution})

    asserts.equals(env, {"": "", _LINUX: "", _MACOS: ""}, result["shared-1.0.0"]["context_map"])
    asserts.equals(env, [""], result["shared-1.0.0"]["definitions"].keys())
    asserts.equals(env, {_LINUX: ["std"]}, _definition(result, "shared-1.0.0")["crate_features_select"])
    asserts.equals(env, set(["std", "dep:optional"]), target["shared-1.0.0"].features_enabled[_LINUX])
    _assert_context_maps(env, result)
    return unittest.end(env)

def _normal_dependency_identity_impl(ctx):
    env = unittest.begin(ctx)
    child = _PREFIX + "child-1.0.0"
    parent = _PREFIX + "parent-1.0.0"
    target = {
        "ancestor-1.0.0": _resolution(deps = {_LINUX: [parent]}),
        "parent-1.0.0": _resolution(deps = {_LINUX: [child]}, aliases = {child: "renamed"}),
        "child-1.0.0": _resolution(features = {_LINUX: ["normal"]}),
    }
    execution = dict(target, **{"child-1.0.0": _resolution(features = {_LINUX: ["build"]})})
    result = _prepare(target, {_LINUX: execution, _MACOS: execution})

    for fq in target:
        asserts.equals(env, {"": "", _LINUX: _MACOS, _MACOS: _MACOS}, result[fq]["context_map"])
        asserts.equals(env, 2, len(result[fq]["definitions"]))
    for context in ["", _LINUX, _MACOS]:
        definition = _definition(result, "parent-1.0.0", context)
        asserts.equals(env, {_LINUX: [child]}, definition["deps_select"])
        asserts.equals(env, {child: "renamed"}, definition["aliases"])
    _assert_context_maps(env, result)
    return unittest.end(env)

def _build_dependency_identity_impl(ctx):
    env = unittest.begin(ctx)
    child = _PREFIX + "child-1.0.0"
    platforms = {_LINUX: [], _MACOS: []}
    target = {
        "parent-1.0.0": _resolution(features = platforms),
        "child-1.0.0": _resolution(features = {_LINUX: ["normal"], _MACOS: ["normal"]}),
    }
    execution = {
        triple: {
            "parent-1.0.0": _resolution(features = platforms, build_deps = {_LINUX: [child], _MACOS: [child]}, aliases = {child: "renamed"}),
            "child-1.0.0": _resolution(features = {_LINUX: [feature], _MACOS: [feature]}),
        }
        for triple, feature in [(_LINUX, "linux"), (_MACOS, "macos")]
    }
    build_deps = {triple: {"parent-1.0.0": {_LINUX: [child], _MACOS: [child]}} for triple in platforms}
    build_aliases = {triple: {"parent-1.0.0": {child: "renamed"}} for triple in platforms}
    result = _prepare(target, execution, build_deps, build_aliases)

    for fq in target:
        asserts.equals(env, {"": "", _LINUX: _LINUX, _MACOS: _MACOS}, result[fq]["context_map"])
    for context in ["", _LINUX, _MACOS]:
        definition = _definition(result, "parent-1.0.0", context)
        asserts.equals(env, {_LINUX: [child], _MACOS: [child]}, definition["build_deps_by_target"][_LINUX])
        asserts.equals(env, {child: "renamed"}, definition["build_aliases_by_target"][_LINUX])
    _assert_context_maps(env, result)
    return unittest.end(env)

def _workspace_dependency_preserves_context_impl(ctx):
    env = unittest.begin(ctx)
    workspace = _PREFIX + "workspace-1.0.0"
    target = {
        "parent-1.0.0": _resolution(deps = {_LINUX: [workspace]}),
        "workspace-1.0.0": _resolution(),
    }
    execution = dict(target, **{"workspace-1.0.0": _resolution(active = False)})
    result = _prepare(target, {_LINUX: execution, _MACOS: execution}, workspace_crates = ["workspace-1.0.0"])

    # Workspace BUILD attributes can read context even without a Cargo execution root.
    for fq in target:
        asserts.equals(env, {"": "", _LINUX: _LINUX, _MACOS: _MACOS}, result[fq]["context_map"])
    asserts.true(env, result["workspace-1.0.0"]["preserve_context"])
    asserts.false(env, result["parent-1.0.0"]["preserve_context"])
    _assert_context_maps(env, result)
    return unittest.end(env)

def _unknown_dependency_preserves_context_impl(ctx):
    env = unittest.begin(ctx)
    target = {
        "normal-1.0.0": _resolution(deps = {_LINUX: ["//helper"]}),
        "build-1.0.0": _resolution(),
    }
    execution = dict(target, **{"build-1.0.0": _resolution(build_deps = {_LINUX: ["//helper"]})})
    result = _prepare(
        target,
        {_LINUX: execution, _MACOS: execution},
        {_LINUX: {"build-1.0.0": {_LINUX: ["//helper"]}}},
    )

    asserts.equals(env, {"": "", _LINUX: _LINUX, _MACOS: _MACOS}, result["normal-1.0.0"]["context_map"])
    asserts.equals(env, {"": "", _LINUX: "", _MACOS: _MACOS}, result["build-1.0.0"]["context_map"])
    _assert_context_maps(env, result)
    return unittest.end(env)

def _sparse_leaf_definitions_share_context_impl(ctx):
    env = unittest.begin(ctx)
    target = {"leaf-1.0.0": _resolution(features = {_LINUX: ["std"]})}
    execution = {_LINUX: {"leaf-1.0.0": _resolution(features = {_MACOS: ["std"]})}}
    result = _prepare(target, execution)

    asserts.equals(env, {"": "", _LINUX: ""}, result["leaf-1.0.0"]["context_map"])
    asserts.equals(env, [""], result["leaf-1.0.0"]["definitions"].keys())
    asserts.equals(env, {_LINUX: ["std"], _MACOS: ["std"]}, _definition(result, "leaf-1.0.0")["crate_features_select"])
    asserts.equals(env, {_LINUX: set(["std"])}, target["leaf-1.0.0"].features_enabled)
    _assert_context_maps(env, result)
    return unittest.end(env)

def _build_script_keeps_original_target_impl(ctx):
    env = unittest.begin(ctx)
    child = _PREFIX + "child-1.0.0"
    target = {
        "parent-1.0.0": _resolution(features = {_LINUX: []}),
        "child-1.0.0": _resolution(features = {_LINUX: []}),
    }
    execution = {
        "parent-1.0.0": _resolution(features = {_MACOS: []}, build_deps = {_MACOS: [child]}),
        "child-1.0.0": _resolution(features = {_MACOS: []}),
    }
    result = _prepare(target, {_LINUX: execution}, {_LINUX: {"parent-1.0.0": {_MACOS: [child]}}})

    # Resetting the parent would make its nested build script set a macOS
    # context, but this Cargo repository resolves build dependencies for Linux.
    asserts.equals(env, {"": "", _LINUX: _LINUX}, result["parent-1.0.0"]["context_map"])
    asserts.equals(env, {"": "", _LINUX: ""}, result["child-1.0.0"]["context_map"])
    asserts.equals(env, {_MACOS: {_MACOS: [child]}}, _definition(result, "parent-1.0.0", _LINUX)["build_deps_by_target"])
    _assert_context_maps(env, result)
    return unittest.end(env)

def _disjoint_platform_dependencies_keep_context_impl(ctx):
    env = unittest.begin(ctx)
    child = _PREFIX + "child-1.0.0"
    target = {
        "parent-1.0.0": _resolution(features = {_LINUX: []}, deps = {_LINUX: [child]}),
        "child-1.0.0": _resolution(features = {_LINUX: ["normal"], _MACOS: ["normal"]}),
    }
    execution = {
        "parent-1.0.0": _resolution(features = {_MACOS: []}, deps = {_MACOS: [child]}),
        "child-1.0.0": _resolution(features = {_LINUX: ["build"], _MACOS: ["build"]}),
    }
    result = _prepare(target, {_LINUX: execution})

    # Merging the parent's platform maps would lose the child's required context.
    asserts.equals(env, {"": "", _LINUX: _LINUX}, result["parent-1.0.0"]["context_map"])
    asserts.equals(env, {_LINUX: [child]}, _definition(result, "parent-1.0.0")["deps_select"])
    asserts.equals(env, {_MACOS: [child]}, _definition(result, "parent-1.0.0", _LINUX)["deps_select"])
    _assert_context_maps(env, result)
    return unittest.end(env)

def _aliases_are_part_of_definition_impl(ctx):
    env = unittest.begin(ctx)
    child = _PREFIX + "child-1.0.0"
    target = {
        "parent-1.0.0": _resolution(deps = {_LINUX: [child]}, aliases = {child: "normal_name"}),
        "unused-1.0.0": _resolution(aliases = {child: "normal_name"}),
        "child-1.0.0": _resolution(),
    }
    execution = dict(target, **{
        "parent-1.0.0": _resolution(deps = {_LINUX: [child]}, aliases = {child: "build_name"}),
        "unused-1.0.0": _resolution(aliases = {child: "build_name"}),
    })
    result = _prepare(target, {_LINUX: execution})

    asserts.equals(env, 2, len(result["parent-1.0.0"]["definitions"]))
    asserts.equals(env, 1, len(result["unused-1.0.0"]["definitions"]))
    asserts.equals(env, {}, _definition(result, "unused-1.0.0")["aliases"])
    _assert_context_maps(env, result)
    return unittest.end(env)

def _direct_execution_only_crate_impl(ctx):
    env = unittest.begin(ctx)
    result = _prepare(
        {"helper-1.0.0": _resolution(active = False)},
        {
            _LINUX: {"helper-1.0.0": _resolution(features = {_LINUX: ["linux"]})},
            _MACOS: {"helper-1.0.0": _resolution(features = {_LINUX: ["macos"]})},
        },
    )

    asserts.equals(env, {"": "", _LINUX: _LINUX, _MACOS: ""}, result["helper-1.0.0"]["context_map"])
    asserts.equals(env, {_LINUX: ["macos"]}, _definition(result, "helper-1.0.0")["crate_features_select"])
    _assert_context_maps(env, result)
    return unittest.end(env)

def _execution_only_dependency_chain_clears_context_impl(ctx):
    env = unittest.begin(ctx)
    child = _PREFIX + "child-1.0.0"
    leaf = _PREFIX + "leaf-1.0.0"
    target = {fq: _resolution(active = False) for fq in ["parent-1.0.0", "child-1.0.0", "leaf-1.0.0"]}
    execution = {
        "parent-1.0.0": _resolution(deps = {_LINUX: [child]}),
        "child-1.0.0": _resolution(deps = {_LINUX: [leaf]}),
        "leaf-1.0.0": _resolution(),
    }
    result = _prepare(target, {_LINUX: execution, _MACOS: execution})

    for fq in target:
        asserts.equals(env, {"": "", _LINUX: "", _MACOS: ""}, result[fq]["context_map"])
        asserts.equals(env, [""], result[fq]["definitions"].keys())
        asserts.equals(env, {_LINUX: ""}, _definition(result, fq)["build_contexts"])
    _assert_context_maps(env, result)
    return unittest.end(env)

def _execution_only_workspace_dependency_keeps_context_impl(ctx):
    env = unittest.begin(ctx)
    helper = _PREFIX + "helper-1.0.0"
    target = {
        "parent-1.0.0": _resolution(active = False),
        "helper-1.0.0": _resolution(),
    }
    execution = {
        "parent-1.0.0": _resolution(deps = {_LINUX: [helper]}),
        "helper-1.0.0": _resolution(),
    }
    result = _prepare(target, {_LINUX: execution}, workspace_crates = ["helper-1.0.0"])

    asserts.equals(env, {"": _LINUX, _LINUX: _LINUX}, result["parent-1.0.0"]["context_map"])
    asserts.equals(env, {"": "", _LINUX: _LINUX}, result["helper-1.0.0"]["context_map"])
    _assert_context_maps(env, result)
    return unittest.end(env)

def _execution_only_nested_build_script_keeps_origin_impl(ctx):
    env = unittest.begin(ctx)
    child = _PREFIX + "child-1.0.0"
    target = {
        "parent-1.0.0": _resolution(active = False),
        "child-1.0.0": _resolution(features = {_MACOS: ["normal"]}),
    }
    execution = {
        "parent-1.0.0": _resolution(features = {_MACOS: []}, build_deps = {_MACOS: [child]}),
        "child-1.0.0": _resolution(features = {_MACOS: ["build"]}),
    }
    result = _prepare(target, {_LINUX: execution})

    # Clearing the parent would request a macOS build context that this
    # repository does not resolve, instead of the original Linux context.
    asserts.equals(env, {"": _LINUX, _LINUX: _LINUX}, result["parent-1.0.0"]["context_map"])
    asserts.equals(env, {_MACOS: _LINUX}, _definition(result, "parent-1.0.0")["build_contexts"])
    asserts.equals(env, {_MACOS: ["build"]}, _definition(result, "child-1.0.0", _LINUX)["crate_features_select"])
    _assert_context_maps(env, result)
    return unittest.end(env)

def _inactive_crate_has_no_supported_platforms_impl(ctx):
    env = unittest.begin(ctx)
    child = _PREFIX + "child-1.0.0"
    target = {
        "inactive-1.0.0": _resolution(features = {_LINUX: ["unused"]}, active = False),
        "child-1.0.0": _resolution(features = {_LINUX: ["normal"]}),
    }
    execution = {
        "inactive-1.0.0": _resolution(active = False),
        "child-1.0.0": _resolution(features = {_LINUX: ["build"]}),
    }
    result = _prepare(
        target,
        {_LINUX: execution},
        {_LINUX: {"inactive-1.0.0": {_LINUX: [child]}}},
    )

    definition = _definition(result, "inactive-1.0.0")
    for field in ["crate_features_select", "deps_select", "aliases", "build_deps_by_target", "build_aliases_by_target", "build_contexts"]:
        asserts.equals(env, {}, definition[field])
    asserts.equals(env, {_LINUX: ["normal"]}, _definition(result, "child-1.0.0")["crate_features_select"])
    asserts.equals(env, {_LINUX: ["build"]}, _definition(result, "child-1.0.0", _LINUX)["crate_features_select"])
    asserts.equals(env, set(), target["inactive-1.0.0"].active)
    asserts.equals(env, {_LINUX: set(["normal"])}, target["child-1.0.0"].features_enabled)
    _assert_context_maps(env, result)
    return unittest.end(env)

def _preserved_execution_only_crate_keeps_default_impl(ctx):
    env = unittest.begin(ctx)
    target = {"helper-1.0.0": _resolution(active = False)}
    execution = {"helper-1.0.0": _resolution(features = {_LINUX: ["build"]})}
    result = _prepare(target, {_LINUX: execution, _MACOS: execution}, preserve_context = ["helper-1.0.0"])

    asserts.equals(env, {"": _MACOS, _LINUX: _LINUX, _MACOS: _MACOS}, result["helper-1.0.0"]["context_map"])
    asserts.equals(env, 2, len(result["helper-1.0.0"]["definitions"]))
    _assert_context_maps(env, result)
    return unittest.end(env)

def _annotation_dependencies_preserve_missing_context_impl(ctx):
    env = unittest.begin(ctx)
    shared = _PREFIX + "shared-1.0.0"
    target = {
        "x-1.0.0": _resolution(features = {_LINUX: ["x"]}),
        "y-1.0.0": _resolution(active = False),
        "helper-1.0.0": _resolution(deps = {_LINUX: [shared]}),
        "shared-1.0.0": _resolution(features = {_LINUX: ["normal"]}),
    }
    execution = {
        "x-1.0.0": _resolution(active = False),
        "y-1.0.0": _resolution(),
        "helper-1.0.0": target["helper-1.0.0"],
        "shared-1.0.0": _resolution(features = {_LINUX: ["build"]}),
    }
    result = _prepare(
        target,
        {_LINUX: execution},
        preserve_context = ["x-1.0.0", "y-1.0.0"],
        workspace_crates = ["helper-1.0.0"],
    )

    # Annotations add Y -> X -> helper after Cargo resolution. X is absent
    # from Cargo's build dependencies but must preserve Y's build context.
    context = _LINUX
    for fq in ["y-1.0.0", "x-1.0.0", "helper-1.0.0"]:
        context = result[fq]["context_map"][context]
        asserts.equals(env, _LINUX, context)
    asserts.equals(env, {_LINUX: ["x"]}, _definition(result, "x-1.0.0", _LINUX)["crate_features_select"])
    asserts.equals(env, {_LINUX: ["build"]}, _definition(result, "shared-1.0.0", context)["crate_features_select"])
    _assert_context_maps(env, result)
    return unittest.end(env)

def _build_script_without_dependencies_clears_context_impl(ctx):
    env = unittest.begin(ctx)
    target = {"parent-1.0.0": _resolution(features = {_LINUX: [], _MACOS: []})}
    result = _prepare(target, {_LINUX: target, _MACOS: target})

    asserts.equals(env, {_LINUX: "", _MACOS: ""}, _definition(result, "parent-1.0.0")["build_contexts"])
    _assert_context_maps(env, result)
    return unittest.end(env)

def _annotation_build_script_dependencies_keep_context_impl(ctx):
    env = unittest.begin(ctx)
    target = {"parent-1.0.0": _resolution(features = {_LINUX: [], _MACOS: []})}
    result = _prepare(target, {_LINUX: target, _MACOS: target}, preserve_context = ["parent-1.0.0"])

    # Annotation tools and data are absent from Cargo's dependency graph.
    for context in ["", _LINUX, _MACOS]:
        asserts.equals(env, {
            triple: context or triple
            for triple in [_LINUX, _MACOS]
        }, _definition(result, "parent-1.0.0", context)["build_contexts"])
    _assert_context_maps(env, result)
    return unittest.end(env)

def _build_script_invariant_dependencies_clear_context_impl(ctx):
    env = unittest.begin(ctx)
    child = _PREFIX + "child-1.0.0"
    platforms = {_LINUX: [], _MACOS: []}
    build_deps = {_LINUX: [child], _MACOS: [child]}
    target = {
        "parent-1.0.0": _resolution(features = platforms),
        "child-1.0.0": _resolution(features = platforms),
    }
    execution = dict(target, **{"parent-1.0.0": _resolution(features = platforms, build_deps = build_deps)})
    result = _prepare(
        target,
        {_LINUX: execution, _MACOS: execution},
        {triple: {"parent-1.0.0": build_deps} for triple in platforms},
    )

    asserts.equals(env, {_LINUX: "", _MACOS: ""}, _definition(result, "parent-1.0.0")["build_contexts"])
    _assert_context_maps(env, result)
    return unittest.end(env)

def _build_script_dependencies_share_execution_context_impl(ctx):
    env = unittest.begin(ctx)
    child = _PREFIX + "child-1.0.0"
    platforms = {_LINUX: [], _MACOS: []}
    build_deps = {_LINUX: [child], _MACOS: [child]}
    target = {
        "parent-1.0.0": _resolution(features = platforms),
        "child-1.0.0": _resolution(features = {triple: ["normal"] for triple in platforms}),
    }
    execution = {
        "parent-1.0.0": _resolution(features = platforms, build_deps = build_deps),
        "child-1.0.0": _resolution(features = {triple: ["build"] for triple in platforms}),
    }
    result = _prepare(
        target,
        {_LINUX: execution, _MACOS: execution},
        {triple: {"parent-1.0.0": build_deps} for triple in platforms},
    )

    asserts.equals(env, {_LINUX: _MACOS, _MACOS: _MACOS}, _definition(result, "parent-1.0.0")["build_contexts"])
    _assert_context_maps(env, result)
    return unittest.end(env)

def _build_script_workspace_dependencies_keep_context_impl(ctx):
    env = unittest.begin(ctx)
    platforms = {_LINUX: [], _MACOS: []}
    for child in [_PREFIX + "helper-1.0.0", "//helper"]:
        build_deps = {_LINUX: [child], _MACOS: [child]}
        target = {
            "parent-1.0.0": _resolution(features = platforms),
            "helper-1.0.0": _resolution(features = platforms),
        }
        execution = dict(target, **{"parent-1.0.0": _resolution(features = platforms, build_deps = build_deps)})
        result = _prepare(
            target,
            {_LINUX: execution, _MACOS: execution},
            {triple: {"parent-1.0.0": build_deps} for triple in platforms},
            workspace_crates = ["helper-1.0.0"],
        )

        for context in ["", _LINUX, _MACOS]:
            asserts.equals(env, {
                triple: context or triple
                for triple in platforms
            }, _definition(result, "parent-1.0.0", context)["build_contexts"])
        _assert_context_maps(env, result)
    return unittest.end(env)

matching_definitions_test = unittest.make(_matching_definitions_impl)
normal_dependency_identity_test = unittest.make(_normal_dependency_identity_impl)
build_dependency_identity_test = unittest.make(_build_dependency_identity_impl)
workspace_dependency_preserves_context_test = unittest.make(_workspace_dependency_preserves_context_impl)
unknown_dependency_preserves_context_test = unittest.make(_unknown_dependency_preserves_context_impl)
sparse_leaf_definitions_share_context_test = unittest.make(_sparse_leaf_definitions_share_context_impl)
build_script_keeps_original_target_test = unittest.make(_build_script_keeps_original_target_impl)
disjoint_platform_dependencies_keep_context_test = unittest.make(_disjoint_platform_dependencies_keep_context_impl)
aliases_are_part_of_definition_test = unittest.make(_aliases_are_part_of_definition_impl)
direct_execution_only_crate_test = unittest.make(_direct_execution_only_crate_impl)
execution_only_dependency_chain_clears_context_test = unittest.make(_execution_only_dependency_chain_clears_context_impl)
execution_only_workspace_dependency_keeps_context_test = unittest.make(_execution_only_workspace_dependency_keeps_context_impl)
execution_only_nested_build_script_keeps_origin_test = unittest.make(_execution_only_nested_build_script_keeps_origin_impl)
inactive_crate_has_no_supported_platforms_test = unittest.make(_inactive_crate_has_no_supported_platforms_impl)
preserved_execution_only_crate_keeps_default_test = unittest.make(_preserved_execution_only_crate_keeps_default_impl)
annotation_dependencies_preserve_missing_context_test = unittest.make(_annotation_dependencies_preserve_missing_context_impl)
build_script_without_dependencies_clears_context_test = unittest.make(_build_script_without_dependencies_clears_context_impl)
annotation_build_script_dependencies_keep_context_test = unittest.make(_annotation_build_script_dependencies_keep_context_impl)
build_script_invariant_dependencies_clear_context_test = unittest.make(_build_script_invariant_dependencies_clear_context_impl)
build_script_dependencies_share_execution_context_test = unittest.make(_build_script_dependencies_share_execution_context_impl)
build_script_workspace_dependencies_keep_context_test = unittest.make(_build_script_workspace_dependencies_keep_context_impl)

def crate_configurations_tests():
    return unittest.suite(
        "crate_configurations_tests",
        matching_definitions_test,
        normal_dependency_identity_test,
        build_dependency_identity_test,
        workspace_dependency_preserves_context_test,
        unknown_dependency_preserves_context_test,
        sparse_leaf_definitions_share_context_test,
        build_script_keeps_original_target_test,
        disjoint_platform_dependencies_keep_context_test,
        aliases_are_part_of_definition_test,
        direct_execution_only_crate_test,
        execution_only_dependency_chain_clears_context_test,
        execution_only_workspace_dependency_keeps_context_test,
        execution_only_nested_build_script_keeps_origin_test,
        inactive_crate_has_no_supported_platforms_test,
        preserved_execution_only_crate_keeps_default_test,
        annotation_dependencies_preserve_missing_context_test,
        build_script_without_dependencies_clears_context_test,
        annotation_build_script_dependencies_keep_context_test,
        build_script_invariant_dependencies_clear_context_test,
        build_script_dependencies_share_execution_context_test,
        build_script_workspace_dependencies_keep_context_test,
    )
