"""Tests for Cargo configuration equivalence and dependency identity."""

load("@bazel_skylib//lib:unittest.bzl", "asserts", "unittest")
load(":crate_configurations.bzl", "prepare_crate_configurations")

_LINUX = "x86_64-unknown-linux-gnu"
_MACOS = "aarch64-apple-darwin"
_PREFIX = "@crates//:"

def _resolution(features = None, deps = None, build_deps = None, active = True):
    features = features if features != None else {_LINUX: []}
    return struct(
        active = set(features) if active else set(),
        features_enabled = {triple: set(values) for triple, values in features.items()},
        deps = deps if deps != None else {triple: {} for triple in features},
        build_deps = build_deps if build_deps != None else {triple: {} for triple in features},
    )

def _prepare(target, execution, build_deps = {}, **kwargs):
    exec_platform_triples = set()
    for resolutions in execution.values():
        for resolution in resolutions.values():
            exec_platform_triples.update(resolution.features_enabled)
    return prepare_crate_configurations(target, {
        cargo_target_triple: struct(resolutions = resolutions, build_deps = build_deps.get(cargo_target_triple, {}))
        for cargo_target_triple, resolutions in execution.items()
    }, _PREFIX, exec_platform_triples, **kwargs)

def _configuration(result, fq, cargo_target_triple = ""):
    crate = result[fq]
    return crate.configurations[crate.cargo_target_triple_map.get(cargo_target_triple, cargo_target_triple)]

def _assert_cargo_target_triple_maps(env, result, target_triples = [_LINUX, _MACOS]):
    for crate in result.values():
        cargo_target_triple_map = crate.cargo_target_triple_map
        for cargo_target_triple, representative in cargo_target_triple_map.items():
            asserts.true(env, cargo_target_triple != representative)
        cargo_target_triples = set([""] + target_triples)
        cargo_target_triples.update(cargo_target_triple_map)
        cargo_target_triples.update(crate.configurations)
        for cargo_target_triple in cargo_target_triples:
            representative = cargo_target_triple_map.get(cargo_target_triple, cargo_target_triple)
            if cargo_target_triple:
                asserts.true(env, representative in ["", cargo_target_triple])
            asserts.equals(env, representative, cargo_target_triple_map.get(representative, representative))
            asserts.true(env, representative in crate.configurations)
        for configuration in crate.configurations.values():
            for platform_triple in configuration["build_cargo_target_triple_required_on"]:
                asserts.true(env, platform_triple in configuration["crate_features_by_triple"])
                asserts.true(env, platform_triple in configuration["build_deps_by_triple"] or "" in configuration["build_deps_by_triple"])

def _matching_definitions_impl(ctx):
    env = unittest.begin(ctx)
    target = {"shared-1.0.0": _resolution(features = {_LINUX: ["std", "dep:optional"]})}
    execution = {"shared-1.0.0": _resolution(features = {_LINUX: ["std"]})}
    result = _prepare(target, {_LINUX: execution, _MACOS: execution})

    asserts.equals(env, {_LINUX: "", _MACOS: ""}, result["shared-1.0.0"].cargo_target_triple_map)
    asserts.equals(env, [""], result["shared-1.0.0"].configurations.keys())
    asserts.equals(env, {_LINUX: ["std"]}, _configuration(result, "shared-1.0.0")["crate_features_by_triple"])
    asserts.equals(env, [], _configuration(result, "shared-1.0.0")["build_cargo_target_triple_required_on"])
    asserts.equals(env, set(["std", "dep:optional"]), target["shared-1.0.0"].features_enabled[_LINUX])
    _assert_cargo_target_triple_maps(env, result)
    return unittest.end(env)

def _normal_dependency_identity_impl(ctx):
    env = unittest.begin(ctx)
    child = _PREFIX + "child-1.0.0"
    parent = _PREFIX + "parent-1.0.0"
    target = {
        "ancestor-1.0.0": _resolution(deps = {_LINUX: {parent: None}}),
        "parent-1.0.0": _resolution(deps = {_LINUX: {child: "renamed"}}),
        "child-1.0.0": _resolution(features = {_LINUX: ["normal"]}),
    }
    execution = dict(target, **{"child-1.0.0": _resolution(features = {_LINUX: ["build"]})})
    result = _prepare(target, {_LINUX: execution, _MACOS: execution})

    for fq in target:
        asserts.equals(env, {}, result[fq].cargo_target_triple_map)
        asserts.equals(env, 3, len(result[fq].configurations))
    for cargo_target_triple in ["", _LINUX, _MACOS]:
        configuration = _configuration(result, "parent-1.0.0", cargo_target_triple)
        asserts.equals(env, {_LINUX: {child: "renamed"}}, configuration["deps_by_triple"])
    _assert_cargo_target_triple_maps(env, result)
    return unittest.end(env)

def _build_dependency_identity_impl(ctx):
    env = unittest.begin(ctx)
    child = _PREFIX + "child-1.0.0"
    platforms = {_LINUX: [], _MACOS: []}
    build_deps_by_exec_triple = {_LINUX: {child: "renamed"}, _MACOS: {}}
    target = {
        "parent-1.0.0": _resolution(features = platforms),
        "child-1.0.0": _resolution(features = {_LINUX: ["normal"], _MACOS: ["normal"]}),
    }
    execution = {
        triple: {
            "parent-1.0.0": _resolution(features = platforms, build_deps = build_deps_by_exec_triple),
            "child-1.0.0": _resolution(features = {_LINUX: [feature], _MACOS: [feature]}),
        }
        for triple, feature in [(_LINUX, "linux"), (_MACOS, "macos")]
    }
    build_deps = {triple: {"parent-1.0.0": build_deps_by_exec_triple} for triple in platforms}
    result = _prepare(target, execution, build_deps)

    for fq in target:
        asserts.equals(env, {}, result[fq].cargo_target_triple_map)
    for cargo_target_triple in ["", _LINUX, _MACOS]:
        configuration = _configuration(result, "parent-1.0.0", cargo_target_triple)
        asserts.equals(env, {"": build_deps_by_exec_triple}, configuration["build_deps_by_triple"])
        asserts.equals(env, platforms, configuration["crate_features_by_triple"])
        asserts.equals(env, [_LINUX, _MACOS], configuration["build_cargo_target_triple_required_on"])
    _assert_cargo_target_triple_maps(env, result)

    macos_build_deps = {_LINUX: {}, _MACOS: {child: "macos_name"}}
    build_deps[_MACOS]["parent-1.0.0"] = macos_build_deps
    result = _prepare(target, execution, build_deps)
    asserts.equals(env, {"": build_deps_by_exec_triple, _MACOS: macos_build_deps}, _configuration(result, "parent-1.0.0")["build_deps_by_triple"])
    _assert_cargo_target_triple_maps(env, result)
    return unittest.end(env)

def _workspace_dependency_preserves_context_impl(ctx):
    env = unittest.begin(ctx)
    workspace = _PREFIX + "workspace-1.0.0"
    for dep in [workspace, "//helper"]:
        target = {
            "parent-1.0.0": _resolution(deps = {_LINUX: {dep: None}}),
            "workspace-1.0.0": _resolution(),
        }
        execution = dict(target, **{"workspace-1.0.0": _resolution(active = False)})
        result = _prepare(target, {_LINUX: execution, _MACOS: execution}, workspace_crates = ["workspace-1.0.0"])

        # Workspace BUILD attributes can read cargo_target_triple even without a Cargo execution root.
        for fq in target:
            asserts.equals(env, {}, result[fq].cargo_target_triple_map)
        _assert_cargo_target_triple_maps(env, result)
    return unittest.end(env)

def _sparse_leaf_definitions_share_context_impl(ctx):
    env = unittest.begin(ctx)
    target = {"leaf-1.0.0": _resolution(features = {_LINUX: ["std"]})}
    execution = {_LINUX: {"leaf-1.0.0": _resolution(features = {_MACOS: ["std"]})}}
    result = _prepare(target, execution)

    asserts.equals(env, {_LINUX: ""}, result["leaf-1.0.0"].cargo_target_triple_map)
    asserts.equals(env, [""], result["leaf-1.0.0"].configurations.keys())
    asserts.equals(env, {_LINUX: ["std"], _MACOS: ["std"]}, _configuration(result, "leaf-1.0.0")["crate_features_by_triple"])
    asserts.equals(env, {_LINUX: set(["std"])}, target["leaf-1.0.0"].features_enabled)
    _assert_cargo_target_triple_maps(env, result, [_LINUX])
    return unittest.end(env)

def _build_script_does_not_use_exec_triple_as_cargo_target_impl(ctx):
    env = unittest.begin(ctx)
    child = _PREFIX + "child-1.0.0"
    target = {
        "parent-1.0.0": _resolution(features = {_LINUX: []}),
        "child-1.0.0": _resolution(features = {_LINUX: []}),
    }
    execution = {
        "parent-1.0.0": _resolution(features = {_MACOS: []}, build_deps = {_MACOS: {child: None}}),
        "child-1.0.0": _resolution(features = {_MACOS: []}),
    }
    result = _prepare(target, {_LINUX: execution}, {_LINUX: {"parent-1.0.0": {_MACOS: {child: None}}}})

    # The parent and its nested build script both clear cargo_target_triple,
    # so macOS execution does not request an unresolved macOS Cargo target.
    asserts.equals(env, {_LINUX: ""}, result["parent-1.0.0"].cargo_target_triple_map)
    asserts.equals(env, {_LINUX: ""}, result["child-1.0.0"].cargo_target_triple_map)
    asserts.equals(env, [], _configuration(result, "parent-1.0.0")["build_cargo_target_triple_required_on"])
    asserts.equals(env, {"": {_MACOS: {child: None}}}, _configuration(result, "parent-1.0.0", _LINUX)["build_deps_by_triple"])
    _assert_cargo_target_triple_maps(env, result, [_LINUX])
    return unittest.end(env)

def _disjoint_platform_dependencies_keep_context_impl(ctx):
    env = unittest.begin(ctx)
    child = _PREFIX + "child-1.0.0"
    target = {
        "parent-1.0.0": _resolution(features = {_LINUX: []}, deps = {_LINUX: {child: None}}),
        "child-1.0.0": _resolution(features = {_LINUX: ["normal"], _MACOS: ["normal"]}),
    }
    execution = {
        "parent-1.0.0": _resolution(features = {_MACOS: []}, deps = {_MACOS: {child: None}}),
        "child-1.0.0": _resolution(features = {_LINUX: ["build"], _MACOS: ["build"]}),
    }
    result = _prepare(target, {_LINUX: execution})

    # Merging the parent's platform maps would lose the child's required cargo_target_triple.
    asserts.equals(env, {}, result["parent-1.0.0"].cargo_target_triple_map)
    asserts.equals(env, {_LINUX: {child: None}}, _configuration(result, "parent-1.0.0")["deps_by_triple"])
    asserts.equals(env, {_MACOS: {child: None}}, _configuration(result, "parent-1.0.0", _LINUX)["deps_by_triple"])
    _assert_cargo_target_triple_maps(env, result, [_LINUX])
    return unittest.end(env)

def _aliases_are_part_of_definition_impl(ctx):
    env = unittest.begin(ctx)
    child = _PREFIX + "child-1.0.0"
    target = {
        "parent-1.0.0": _resolution(deps = {_LINUX: {child: "normal_name"}}),
        "child-1.0.0": _resolution(),
    }
    execution = dict(target, **{
        "parent-1.0.0": _resolution(deps = {_LINUX: {child: "build_name"}}),
    })
    result = _prepare(target, {_LINUX: execution})

    asserts.equals(env, 2, len(result["parent-1.0.0"].configurations))
    _assert_cargo_target_triple_maps(env, result, [_LINUX])
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

    asserts.equals(env, {"": _MACOS}, result["helper-1.0.0"].cargo_target_triple_map)
    asserts.equals(env, {_LINUX: ["macos"]}, _configuration(result, "helper-1.0.0")["crate_features_by_triple"])
    _assert_cargo_target_triple_maps(env, result)
    return unittest.end(env)

def _execution_only_dependency_chain_clears_context_impl(ctx):
    env = unittest.begin(ctx)
    child = _PREFIX + "child-1.0.0"
    leaf = _PREFIX + "leaf-1.0.0"
    target = {fq: _resolution(active = False) for fq in ["parent-1.0.0", "child-1.0.0", "leaf-1.0.0"]}
    execution = {
        "parent-1.0.0": _resolution(deps = {_LINUX: {child: None}}),
        "child-1.0.0": _resolution(deps = {_LINUX: {leaf: None}}),
        "leaf-1.0.0": _resolution(),
    }
    result = _prepare(target, {_LINUX: execution, _MACOS: execution})

    for fq in target:
        asserts.equals(env, {_LINUX: "", _MACOS: ""}, result[fq].cargo_target_triple_map)
        asserts.equals(env, [""], result[fq].configurations.keys())
        asserts.equals(env, [], _configuration(result, fq)["build_cargo_target_triple_required_on"])
    _assert_cargo_target_triple_maps(env, result)
    return unittest.end(env)

def _execution_only_workspace_dependency_keeps_context_impl(ctx):
    env = unittest.begin(ctx)
    helper = _PREFIX + "helper-1.0.0"
    target = {
        "parent-1.0.0": _resolution(active = False),
        "helper-1.0.0": _resolution(),
    }
    execution = {
        "parent-1.0.0": _resolution(deps = {_LINUX: {helper: None}}),
        "helper-1.0.0": _resolution(),
    }
    result = _prepare(target, {_LINUX: execution}, workspace_crates = ["helper-1.0.0"])

    asserts.equals(env, {"": _LINUX}, result["parent-1.0.0"].cargo_target_triple_map)
    asserts.equals(env, {}, result["helper-1.0.0"].cargo_target_triple_map)
    _assert_cargo_target_triple_maps(env, result, [_LINUX])
    return unittest.end(env)

def _execution_only_nested_build_script_keeps_origin_impl(ctx):
    env = unittest.begin(ctx)
    child = _PREFIX + "child-1.0.0"
    target = {
        "parent-1.0.0": _resolution(active = False),
        "child-1.0.0": _resolution(features = {_MACOS: ["normal"]}),
    }
    execution = {
        "parent-1.0.0": _resolution(features = {_MACOS: []}, build_deps = {_MACOS: {child: None}}),
        "child-1.0.0": _resolution(features = {_MACOS: ["build"]}),
    }
    result = _prepare(target, {_LINUX: execution})

    # Clearing the parent would request a macOS build cargo_target_triple that this
    # repository does not resolve, instead of the original Linux cargo_target_triple.
    asserts.equals(env, {"": _LINUX}, result["parent-1.0.0"].cargo_target_triple_map)
    asserts.equals(env, [_MACOS], _configuration(result, "parent-1.0.0")["build_cargo_target_triple_required_on"])
    asserts.equals(env, {_MACOS: ["build"]}, _configuration(result, "child-1.0.0", _LINUX)["crate_features_by_triple"])
    _assert_cargo_target_triple_maps(env, result, [_LINUX])
    return unittest.end(env)

def _inactive_crate_has_no_supported_platforms_impl(ctx):
    env = unittest.begin(ctx)
    target = {
        "inactive-1.0.0": _resolution(features = {_LINUX: ["unused"]}, active = False),
    }
    execution = {
        "inactive-1.0.0": _resolution(active = False),
    }
    result = _prepare(target, {_LINUX: execution})

    configuration = _configuration(result, "inactive-1.0.0")
    for field in ["crate_features_by_triple", "deps_by_triple", "build_deps_by_triple"]:
        asserts.equals(env, {}, configuration[field])
    asserts.equals(env, [], configuration["build_cargo_target_triple_required_on"])
    asserts.equals(env, set(), target["inactive-1.0.0"].active)
    _assert_cargo_target_triple_maps(env, result, [_LINUX])
    return unittest.end(env)

def _preserved_execution_only_crate_keeps_default_impl(ctx):
    env = unittest.begin(ctx)
    target = {"helper-1.0.0": _resolution(active = False)}
    execution = {"helper-1.0.0": _resolution(features = {_LINUX: ["build"]})}
    result = _prepare(target, {_LINUX: execution, _MACOS: execution}, preserve_cargo_target_triple = ["helper-1.0.0"])

    asserts.equals(env, {"": _MACOS}, result["helper-1.0.0"].cargo_target_triple_map)
    asserts.equals(env, 2, len(result["helper-1.0.0"].configurations))
    _assert_cargo_target_triple_maps(env, result)
    return unittest.end(env)

def _annotation_dependencies_preserve_missing_context_impl(ctx):
    env = unittest.begin(ctx)
    shared = _PREFIX + "shared-1.0.0"
    target = {
        "x-1.0.0": _resolution(features = {_LINUX: ["x"]}),
        "y-1.0.0": _resolution(active = False),
        "helper-1.0.0": _resolution(deps = {_LINUX: {shared: None}}),
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
        preserve_cargo_target_triple = ["x-1.0.0", "y-1.0.0"],
        workspace_crates = ["helper-1.0.0"],
    )

    # Annotations add Y -> X -> helper after Cargo resolution. X is absent
    # from Cargo's build dependencies but must preserve Y's build cargo_target_triple.
    cargo_target_triple = _LINUX
    for fq in ["y-1.0.0", "x-1.0.0", "helper-1.0.0"]:
        cargo_target_triple = result[fq].cargo_target_triple_map.get(cargo_target_triple, cargo_target_triple)
        asserts.equals(env, _LINUX, cargo_target_triple)
    asserts.equals(env, {_LINUX: ["x"]}, _configuration(result, "x-1.0.0", _LINUX)["crate_features_by_triple"])
    asserts.equals(env, {_LINUX: ["build"]}, _configuration(result, "shared-1.0.0", cargo_target_triple)["crate_features_by_triple"])
    _assert_cargo_target_triple_maps(env, result, [_LINUX])
    return unittest.end(env)

def _missing_execution_context_keeps_transitive_dependencies_impl(ctx):
    env = unittest.begin(ctx)
    child = _PREFIX + "child-1.0.0"
    leaf = _PREFIX + "leaf-1.0.0"
    target = {
        "parent-1.0.0": _resolution(features = {_LINUX: ["parent"]}, deps = {_LINUX: {child: None}}),
        "child-1.0.0": _resolution(deps = {_LINUX: {leaf: None}}),
        "leaf-1.0.0": _resolution(features = {_LINUX: ["normal"]}),
    }
    execution = {
        "parent-1.0.0": _resolution(active = False),
        "child-1.0.0": _resolution(active = False),
        "leaf-1.0.0": _resolution(features = {_LINUX: ["build"]}),
    }
    result = _prepare(target, {_LINUX: execution, _MACOS: execution})

    # An annotation can reach parent even though Cargo never reaches parent or
    # child in an execution resolution. Both must preserve leaf's build cargo_target_triple.
    for fq in target:
        asserts.equals(env, {}, result[fq].cargo_target_triple_map)
    for cargo_target_triple in [_LINUX, _MACOS]:
        parent = _configuration(result, "parent-1.0.0", cargo_target_triple)
        asserts.equals(env, {_LINUX: ["parent"]}, parent["crate_features_by_triple"])
        asserts.equals(env, {_LINUX: {child: None}}, parent["deps_by_triple"])
        asserts.equals(env, {_LINUX: {leaf: None}}, _configuration(result, "child-1.0.0", cargo_target_triple)["deps_by_triple"])
        asserts.equals(env, {_LINUX: ["build"]}, _configuration(result, "leaf-1.0.0", cargo_target_triple)["crate_features_by_triple"])
    _assert_cargo_target_triple_maps(env, result)
    return unittest.end(env)

def _annotation_build_script_dependencies_keep_context_impl(ctx):
    env = unittest.begin(ctx)
    target = {"parent-1.0.0": _resolution(features = {_LINUX: [], _MACOS: []})}
    result = _prepare(target, {_LINUX: target, _MACOS: target}, preserve_cargo_target_triple = ["parent-1.0.0"])

    # Annotation tools and data are absent from Cargo's dependency graph.
    for cargo_target_triple in ["", _LINUX, _MACOS]:
        asserts.equals(env, [_LINUX, _MACOS], _configuration(result, "parent-1.0.0", cargo_target_triple)["build_cargo_target_triple_required_on"])
    _assert_cargo_target_triple_maps(env, result)
    return unittest.end(env)

def _build_script_workspace_dependencies_keep_context_impl(ctx):
    env = unittest.begin(ctx)
    platforms = {_LINUX: [], _MACOS: []}
    for child in [_PREFIX + "helper-1.0.0", "//helper"]:
        build_deps = {_LINUX: {child: None}, _MACOS: {child: None}}
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

        for cargo_target_triple in ["", _LINUX, _MACOS]:
            asserts.equals(env, [_LINUX, _MACOS], _configuration(result, "parent-1.0.0", cargo_target_triple)["build_cargo_target_triple_required_on"])
        _assert_cargo_target_triple_maps(env, result)
    return unittest.end(env)

matching_definitions_test = unittest.make(_matching_definitions_impl)
normal_dependency_identity_test = unittest.make(_normal_dependency_identity_impl)
build_dependency_identity_test = unittest.make(_build_dependency_identity_impl)
workspace_dependency_preserves_context_test = unittest.make(_workspace_dependency_preserves_context_impl)
sparse_leaf_definitions_share_context_test = unittest.make(_sparse_leaf_definitions_share_context_impl)
build_script_does_not_use_exec_triple_as_cargo_target_test = unittest.make(_build_script_does_not_use_exec_triple_as_cargo_target_impl)
disjoint_platform_dependencies_keep_context_test = unittest.make(_disjoint_platform_dependencies_keep_context_impl)
aliases_are_part_of_definition_test = unittest.make(_aliases_are_part_of_definition_impl)
direct_execution_only_crate_test = unittest.make(_direct_execution_only_crate_impl)
execution_only_dependency_chain_clears_context_test = unittest.make(_execution_only_dependency_chain_clears_context_impl)
execution_only_workspace_dependency_keeps_context_test = unittest.make(_execution_only_workspace_dependency_keeps_context_impl)
execution_only_nested_build_script_keeps_origin_test = unittest.make(_execution_only_nested_build_script_keeps_origin_impl)
inactive_crate_has_no_supported_platforms_test = unittest.make(_inactive_crate_has_no_supported_platforms_impl)
preserved_execution_only_crate_keeps_default_test = unittest.make(_preserved_execution_only_crate_keeps_default_impl)
annotation_dependencies_preserve_missing_context_test = unittest.make(_annotation_dependencies_preserve_missing_context_impl)
missing_execution_context_keeps_transitive_dependencies_test = unittest.make(_missing_execution_context_keeps_transitive_dependencies_impl)
annotation_build_script_dependencies_keep_context_test = unittest.make(_annotation_build_script_dependencies_keep_context_impl)
build_script_workspace_dependencies_keep_context_test = unittest.make(_build_script_workspace_dependencies_keep_context_impl)

def crate_configurations_tests():
    return unittest.suite(
        "crate_configurations_tests",
        matching_definitions_test,
        normal_dependency_identity_test,
        build_dependency_identity_test,
        workspace_dependency_preserves_context_test,
        sparse_leaf_definitions_share_context_test,
        build_script_does_not_use_exec_triple_as_cargo_target_test,
        disjoint_platform_dependencies_keep_context_test,
        aliases_are_part_of_definition_test,
        direct_execution_only_crate_test,
        execution_only_dependency_chain_clears_context_test,
        execution_only_workspace_dependency_keeps_context_test,
        execution_only_nested_build_script_keeps_origin_test,
        inactive_crate_has_no_supported_platforms_test,
        preserved_execution_only_crate_keeps_default_test,
        annotation_dependencies_preserve_missing_context_test,
        missing_execution_context_keeps_transitive_dependencies_test,
        annotation_build_script_dependencies_keep_context_test,
        build_script_workspace_dependencies_keep_context_test,
    )
