"""Tests for crate definitions shared across target and execution resolutions."""

load("@bazel_skylib//lib:unittest.bzl", "asserts", "unittest")
load(":exec_dependency_labels.bzl", "prepare_dependency_variants")

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

def _prepare(target, execution, build_deps = {}, build_aliases = {}):
    return prepare_dependency_variants(target, execution, build_deps, build_aliases, _PREFIX)

def _variant(result, fq, origin = None):
    suffix = result.exec_suffixes_by_target[origin][fq] if origin else ""
    return [variant for variant in result.variants_by_crate[fq] if variant["name_suffix"] == suffix][0]

def _label(result, fq, origin):
    label = _PREFIX + fq
    return result.exec_labels_by_target[origin].get(label, label)

def _matching_and_inactive_resolutions_impl(ctx):
    env = unittest.begin(ctx)
    target = {
        "shared-1.0.0": _resolution(features = {_LINUX: ["std", "dep:optional"]}),
        "target-only-1.0.0": _resolution(features = {_LINUX: ["target"]}),
        "exec-only-1.0.0": _resolution(active = False),
        "inactive-1.0.0": _resolution(active = False),
    }
    execution = {
        "shared-1.0.0": _resolution(features = {_LINUX: ["std"]}),
        "target-only-1.0.0": _resolution(active = False),
        "exec-only-1.0.0": _resolution(features = {_MACOS: ["exec"]}),
        "inactive-1.0.0": _resolution(active = False),
    }
    result = _prepare(target, {_LINUX: execution, _MACOS: execution})

    asserts.equals(env, {_LINUX: {}, _MACOS: {}}, result.exec_labels_by_target)
    for variants in result.variants_by_crate.values():
        asserts.equals(env, 1, len(variants))
        asserts.equals(env, "", variants[0]["name_suffix"])
    asserts.equals(env, {_LINUX: ["std"]}, _variant(result, "shared-1.0.0")["crate_features_select"])
    asserts.false(env, "inactive-1.0.0" in result.exec_suffixes_by_target[_LINUX])
    asserts.false(env, "target-only-1.0.0" in result.exec_suffixes_by_target[_LINUX])
    asserts.equals(env, set(["std", "dep:optional"]), target["shared-1.0.0"].features_enabled[_LINUX])
    asserts.equals(env, result.variants_by_crate, json.decode(json.encode(result.variants_by_crate)))
    return unittest.end(env)

def _normal_dependency_refinement_impl(ctx):
    env = unittest.begin(ctx)
    parent = _PREFIX + "parent-1.0.0"
    child = _PREFIX + "child-1.0.0"
    target = {
        "grandparent-1.0.0": _resolution(deps = {_LINUX: [parent]}),
        "parent-1.0.0": _resolution(deps = {_LINUX: [child]}, aliases = {child: "renamed"}),
        "child-1.0.0": _resolution(features = {_LINUX: ["target"]}),
    }
    execution = dict(target)
    execution["child-1.0.0"] = _resolution(features = {_LINUX: ["exec"]})
    result = _prepare(target, {_LINUX: execution, _MACOS: execution})

    for fq in target:
        asserts.equals(env, 2, len(result.variants_by_crate[fq]))
        asserts.equals(env, "_exec", result.exec_suffixes_by_target[_LINUX][fq])
        asserts.equals(env, _label(result, fq, _LINUX), _label(result, fq, _MACOS))
    exec_child = _label(result, "child-1.0.0", _LINUX)
    asserts.equals(env, {_LINUX: [child]}, _variant(result, "parent-1.0.0")["deps_select"])
    asserts.equals(env, {_LINUX: [exec_child]}, _variant(result, "parent-1.0.0", _LINUX)["deps_select"])
    asserts.equals(env, {exec_child: "renamed"}, _variant(result, "parent-1.0.0", _LINUX)["aliases"])
    asserts.equals(env, set([child]), execution["parent-1.0.0"].deps[_LINUX])
    asserts.equals(env, {child: "renamed"}, execution["parent-1.0.0"].aliases)
    return unittest.end(env)

def _build_dependency_refinement_impl(ctx):
    env = unittest.begin(ctx)
    child = _PREFIX + "child-1.0.0"
    parent = _PREFIX + "parent-1.0.0"
    target = {
        "child-1.0.0": _resolution(features = {_LINUX: ["target"], _MACOS: ["target"]}),
        "parent-1.0.0": _resolution(features = {_LINUX: [], _MACOS: []}),
        "normal-ancestor-1.0.0": _resolution(
            features = {_LINUX: [], _MACOS: []},
            deps = {_LINUX: [parent], _MACOS: [parent]},
        ),
        "build-ancestor-1.0.0": _resolution(features = {_LINUX: [], _MACOS: []}),
    }
    execution = {}
    for triple, feature in [(_LINUX, "linux"), (_MACOS, "macos")]:
        execution[triple] = {
            "child-1.0.0": _resolution(features = {_MACOS: [feature]}),
            "parent-1.0.0": _resolution(features = {_MACOS: []}, build_deps = {_MACOS: [child]}, aliases = {child: "build_child"}),
            "normal-ancestor-1.0.0": _resolution(features = {_MACOS: []}, deps = {_MACOS: [parent]}),
            "build-ancestor-1.0.0": _resolution(features = {_MACOS: []}, build_deps = {_MACOS: [parent]}),
        }
    target_build_deps = {
        triple: {
            "parent-1.0.0": {_MACOS: [child]},
            "build-ancestor-1.0.0": {_MACOS: [parent]},
        }
        for triple in [_LINUX, _MACOS]
    }
    target_build_aliases = {
        triple: {"parent-1.0.0": {child: "build_child"}}
        for triple in [_LINUX, _MACOS]
    }
    result = _prepare(target, execution, target_build_deps, target_build_aliases)

    asserts.equals(env, 3, len(result.variants_by_crate["child-1.0.0"]))
    for triple in [_LINUX, _MACOS]:
        asserts.equals(env, "_exec_" + triple, result.exec_suffixes_by_target[triple]["child-1.0.0"])
    asserts.equals(env, {_MACOS: ["linux"]}, _variant(result, "child-1.0.0", _LINUX)["crate_features_select"])
    asserts.equals(env, {_MACOS: ["macos"]}, _variant(result, "child-1.0.0", _MACOS)["crate_features_select"])
    for fq in ["parent-1.0.0", "normal-ancestor-1.0.0", "build-ancestor-1.0.0"]:
        asserts.equals(env, 2, len(result.variants_by_crate[fq]))
        asserts.equals(env, "", result.exec_suffixes_by_target[_MACOS][fq])
        asserts.equals(env, "_exec", result.exec_suffixes_by_target[_LINUX][fq])

    linux_child = _label(result, "child-1.0.0", _LINUX)
    macos_child = _label(result, "child-1.0.0", _MACOS)
    canonical_parent = _variant(result, "parent-1.0.0")
    linux_parent = _variant(result, "parent-1.0.0", _LINUX)
    asserts.equals(env, [linux_child], canonical_parent["build_deps_by_target"][_LINUX][_MACOS])
    asserts.equals(env, [macos_child], canonical_parent["build_deps_by_target"][_MACOS][_MACOS])
    asserts.equals(env, [linux_child], linux_parent["build_deps_by_target"][_MACOS][_MACOS])
    asserts.equals(env, {linux_child: "build_child"}, linux_parent["build_aliases_by_target"][_MACOS])
    asserts.equals(
        env,
        [_label(result, "parent-1.0.0", _LINUX)],
        _variant(result, "build-ancestor-1.0.0", _LINUX)["build_deps_by_target"][_MACOS][_MACOS],
    )
    return unittest.end(env)

def _disjoint_compile_platforms_impl(ctx):
    env = unittest.begin(ctx)
    child = _PREFIX + "child-1.0.0"
    target = {
        "parent-1.0.0": _resolution(features = {_LINUX: ["target"]}, deps = {_LINUX: [child]}, aliases = {child: "normal_child"}),
        "child-1.0.0": _resolution(features = {_LINUX: ["target"]}),
    }
    execution = {
        "parent-1.0.0": _resolution(
            features = {_MACOS: ["exec"]},
            build_deps = {_MACOS: [child]},
            aliases = {child: "build_child"},
        ),
        "child-1.0.0": _resolution(features = {_LINUX: ["exec"]}),
    }
    result = _prepare(target, {_LINUX: execution})
    variant = _variant(result, "parent-1.0.0")

    asserts.equals(env, 1, len(result.variants_by_crate["parent-1.0.0"]))
    asserts.equals(env, {_LINUX: ["target"], _MACOS: ["exec"]}, variant["crate_features_select"])
    asserts.equals(env, {child: "normal_child"}, variant["aliases"])
    asserts.equals(env, {}, variant["build_aliases_by_target"][_LINUX])
    asserts.equals(env, {_label(result, "child-1.0.0", _LINUX): "build_child"}, variant["build_aliases_by_target"][_MACOS])
    asserts.equals(env, "", result.exec_suffixes_by_target[_LINUX]["parent-1.0.0"])
    return unittest.end(env)

def _alias_conflicts_and_unused_aliases_impl(ctx):
    env = unittest.begin(ctx)
    dependency = _PREFIX + "dependency-1.0.0"
    target = {
        "normal-1.0.0": _resolution(deps = {_LINUX: [dependency]}, aliases = {dependency: "target_name"}),
        "build-1.0.0": _resolution(),
        "unused-1.0.0": _resolution(aliases = {dependency: "target_name"}),
    }
    execution = {}
    for triple, rename in [(_LINUX, "linux_name"), (_MACOS, "macos_name")]:
        execution[triple] = {
            "normal-1.0.0": _resolution(deps = {_LINUX: [dependency]}, aliases = {dependency: rename}),
            "build-1.0.0": _resolution(build_deps = {_LINUX: [dependency]}, aliases = {dependency: rename}),
            "unused-1.0.0": _resolution(aliases = {dependency: rename}),
        }
    result = _prepare(
        target,
        execution,
        {_LINUX: {"build-1.0.0": {_LINUX: [dependency]}}},
        {_LINUX: {"build-1.0.0": {dependency: "target_name"}}},
    )

    asserts.equals(env, 3, len(result.variants_by_crate["normal-1.0.0"]))
    asserts.equals(env, 3, len(result.variants_by_crate["build-1.0.0"]))
    asserts.equals(env, 1, len(result.variants_by_crate["unused-1.0.0"]))
    asserts.equals(env, {}, _variant(result, "unused-1.0.0")["aliases"])
    asserts.equals(env, {dependency: "linux_name"}, _variant(result, "normal-1.0.0", _LINUX)["aliases"])
    asserts.equals(env, {dependency: "macos_name"}, _variant(result, "build-1.0.0", _MACOS)["build_aliases_by_target"][_LINUX])
    return unittest.end(env)

def _missing_build_matrix_means_no_dependencies_impl(ctx):
    env = unittest.begin(ctx)
    dependency = _PREFIX + "dependency-1.0.0"
    result = _prepare(
        {"parent-1.0.0": _resolution()},
        {_LINUX: {"parent-1.0.0": _resolution(build_deps = {_LINUX: [dependency]})}},
    )

    asserts.equals(env, 2, len(result.variants_by_crate["parent-1.0.0"]))
    asserts.equals(env, {_LINUX: []}, _variant(result, "parent-1.0.0")["build_deps_by_target"][_LINUX])
    asserts.equals(env, {_LINUX: [dependency]}, _variant(result, "parent-1.0.0", _LINUX)["build_deps_by_target"][_LINUX])
    return unittest.end(env)

def _exec_only_canonical_definition_impl(ctx):
    env = unittest.begin(ctx)
    result = _prepare(
        {"helper-1.0.0": _resolution(active = False)},
        {
            _LINUX: {"helper-1.0.0": _resolution(features = {_MACOS: ["linux_target"]})},
            _MACOS: {"helper-1.0.0": _resolution(features = {_MACOS: ["macos_target"]})},
        },
    )

    asserts.equals(env, 2, len(result.variants_by_crate["helper-1.0.0"]))
    asserts.equals(env, "", result.exec_suffixes_by_target[_MACOS]["helper-1.0.0"])
    asserts.equals(env, "_exec", result.exec_suffixes_by_target[_LINUX]["helper-1.0.0"])
    asserts.equals(env, {_MACOS: ["macos_target"]}, _variant(result, "helper-1.0.0")["crate_features_select"])
    asserts.equals(env, {}, result.exec_labels_by_target[_MACOS])
    return unittest.end(env)

def _merged_platforms_do_not_unify_conflicting_features_impl(ctx):
    env = unittest.begin(ctx)
    target = {"shared-1.0.0": _resolution(features = {_LINUX: ["target"]})}
    linux_execution = {"shared-1.0.0": _resolution(features = {_LINUX: ["linux_exec"]})}
    macos_execution = {"shared-1.0.0": _resolution(features = {_MACOS: ["macos_exec"]})}
    result = _prepare(target, {_LINUX: linux_execution, _MACOS: macos_execution})
    reordered = _prepare(target, {_MACOS: macos_execution, _LINUX: linux_execution})

    asserts.equals(env, 2, len(result.variants_by_crate["shared-1.0.0"]))
    asserts.equals(env, {_LINUX: ["target"], _MACOS: ["macos_exec"]}, _variant(result, "shared-1.0.0")["crate_features_select"])
    asserts.equals(env, {_LINUX: ["linux_exec"]}, _variant(result, "shared-1.0.0", _LINUX)["crate_features_select"])
    asserts.equals(env, result.variants_by_crate, reordered.variants_by_crate)
    asserts.equals(env, result.exec_labels_by_target, reordered.exec_labels_by_target)
    return unittest.end(env)

matching_and_inactive_resolutions_test = unittest.make(_matching_and_inactive_resolutions_impl)
normal_dependency_refinement_test = unittest.make(_normal_dependency_refinement_impl)
build_dependency_refinement_test = unittest.make(_build_dependency_refinement_impl)
disjoint_compile_platforms_test = unittest.make(_disjoint_compile_platforms_impl)
alias_conflicts_and_unused_aliases_test = unittest.make(_alias_conflicts_and_unused_aliases_impl)
missing_build_matrix_means_no_dependencies_test = unittest.make(_missing_build_matrix_means_no_dependencies_impl)
exec_only_canonical_definition_test = unittest.make(_exec_only_canonical_definition_impl)
merged_platforms_do_not_unify_conflicting_features_test = unittest.make(_merged_platforms_do_not_unify_conflicting_features_impl)

def exec_dependency_labels_tests():
    return unittest.suite(
        "exec_dependency_labels_tests",
        matching_and_inactive_resolutions_test,
        normal_dependency_refinement_test,
        build_dependency_refinement_test,
        disjoint_compile_platforms_test,
        alias_conflicts_and_unused_aliases_test,
        missing_build_matrix_means_no_dependencies_test,
        exec_only_canonical_definition_test,
        merged_platforms_do_not_unify_conflicting_features_test,
    )
