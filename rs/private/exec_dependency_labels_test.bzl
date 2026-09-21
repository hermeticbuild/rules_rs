"""Tests for explicit target and execution dependency labels."""

load("@bazel_skylib//lib:unittest.bzl", "asserts", "unittest")
load(":exec_dependency_labels.bzl", "prepare_exec_dependency_labels")

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

def _matching_features_and_single_resolution_impl(ctx):
    env = unittest.begin(ctx)
    target = {
        "shared-1.0.0": _resolution(features = {_LINUX: ["std", "dep:optional"]}),
        "target-only-1.0.0": _resolution(features = {_LINUX: ["target"]}),
        "exec-only-1.0.0": _resolution(active = False),
    }
    execution = {
        "shared-1.0.0": _resolution(features = {_LINUX: ["std"]}),
        "target-only-1.0.0": _resolution(active = False),
        "exec-only-1.0.0": _resolution(features = {_MACOS: ["exec"]}),
    }

    result = prepare_exec_dependency_labels(target, execution, _PREFIX)

    asserts.equals(env, set(), result.split_crates)
    asserts.equals(env, {}, result.exec_labels)
    asserts.equals(env, set(["std", "dep:optional"]), target["shared-1.0.0"].features_enabled[_LINUX])
    return unittest.end(env)

def _split_propagates_to_normal_ancestors_impl(ctx):
    env = unittest.begin(ctx)
    parent = _PREFIX + "parent-1.0.0"
    child = _PREFIX + "child-1.0.0"
    target = {
        "grandparent-1.0.0": _resolution(deps = {_LINUX: [parent]}),
        "parent-1.0.0": _resolution(deps = {_LINUX: [child]}, aliases = {child: "renamed"}),
        "build-parent-1.0.0": _resolution(build_deps = {_LINUX: [child]}, aliases = {child: "renamed"}),
        "child-1.0.0": _resolution(features = {_LINUX: ["target"]}),
    }
    execution = dict(target)
    execution["child-1.0.0"] = _resolution(features = {_LINUX: ["exec"]})

    result = prepare_exec_dependency_labels(target, execution, _PREFIX)

    expected_splits = set(["grandparent-1.0.0", "parent-1.0.0", "child-1.0.0"])
    asserts.equals(env, expected_splits, result.split_crates)
    asserts.equals(env, {
        _PREFIX + fq: _PREFIX + "__exec/" + fq
        for fq in expected_splits
    }, result.exec_labels)
    asserts.equals(env, set([child]), execution["parent-1.0.0"].deps[_LINUX])
    asserts.equals(env, {child: "renamed"}, execution["parent-1.0.0"].aliases)
    return unittest.end(env)

def _disjoint_platforms_can_share_definition_impl(ctx):
    env = unittest.begin(ctx)
    child = _PREFIX + "child-1.0.0"
    target = {
        "parent-1.0.0": _resolution(
            features = {_LINUX: ["target"]},
            deps = {_LINUX: [child]},
            aliases = {child: "renamed"},
        ),
        "child-1.0.0": _resolution(features = {_LINUX: ["target"]}),
    }
    execution = {
        "parent-1.0.0": _resolution(
            features = {_MACOS: ["exec"]},
            deps = {_MACOS: [child]},
            aliases = {child: "renamed"},
        ),
        "child-1.0.0": _resolution(features = {_LINUX: ["exec"]}),
    }

    result = prepare_exec_dependency_labels(target, execution, _PREFIX)

    asserts.equals(env, set(["child-1.0.0"]), result.split_crates)
    return unittest.end(env)

def _renamed_dependencies_require_distinct_definitions_impl(ctx):
    env = unittest.begin(ctx)
    dependency = _PREFIX + "dependency-1.0.0"
    unused = _PREFIX + "unused-1.0.0"
    target = {
        "normal-1.0.0": _resolution(deps = {_LINUX: [dependency]}, aliases = {dependency: "target_name"}),
        "build-1.0.0": _resolution(build_deps = {_LINUX: [dependency]}, aliases = {dependency: "target_name"}),
        "unused-1.0.0": _resolution(aliases = {unused: "target_name"}),
    }
    execution = {
        "normal-1.0.0": _resolution(deps = {_LINUX: [dependency]}, aliases = {dependency: "exec_name"}),
        "build-1.0.0": _resolution(build_deps = {_LINUX: [dependency]}, aliases = {dependency: "exec_name"}),
        "unused-1.0.0": _resolution(aliases = {unused: "exec_name"}),
    }

    result = prepare_exec_dependency_labels(target, execution, _PREFIX)

    asserts.equals(env, set(["normal-1.0.0", "build-1.0.0"]), result.split_crates)
    return unittest.end(env)

def _different_dependency_sets_require_distinct_definitions_impl(ctx):
    env = unittest.begin(ctx)
    dependency = _PREFIX + "dependency-1.0.0"
    target = {
        "normal-1.0.0": _resolution(),
        "build-1.0.0": _resolution(),
    }
    execution = {
        "normal-1.0.0": _resolution(deps = {_LINUX: [dependency]}),
        "build-1.0.0": _resolution(build_deps = {_LINUX: [dependency]}),
    }

    result = prepare_exec_dependency_labels(target, execution, _PREFIX)

    asserts.equals(env, set(["normal-1.0.0", "build-1.0.0"]), result.split_crates)
    return unittest.end(env)

def _normal_and_build_aliases_are_compared_separately_impl(ctx):
    env = unittest.begin(ctx)
    dependency = _PREFIX + "dependency-1.0.0"
    target = {
        "parent-1.0.0": _resolution(
            deps = {_LINUX: [dependency]},
            aliases = {dependency: "normal_name"},
        ),
    }
    execution = {
        "parent-1.0.0": _resolution(
            features = {_MACOS: []},
            build_deps = {_MACOS: [dependency]},
            aliases = {dependency: "build_name"},
        ),
    }

    result = prepare_exec_dependency_labels(target, execution, _PREFIX)

    asserts.equals(env, set(), result.split_crates)
    return unittest.end(env)

matching_features_and_single_resolution_test = unittest.make(_matching_features_and_single_resolution_impl)
split_propagates_to_normal_ancestors_test = unittest.make(_split_propagates_to_normal_ancestors_impl)
disjoint_platforms_can_share_definition_test = unittest.make(_disjoint_platforms_can_share_definition_impl)
renamed_dependencies_require_distinct_definitions_test = unittest.make(_renamed_dependencies_require_distinct_definitions_impl)
different_dependency_sets_require_distinct_definitions_test = unittest.make(_different_dependency_sets_require_distinct_definitions_impl)
normal_and_build_aliases_are_compared_separately_test = unittest.make(_normal_and_build_aliases_are_compared_separately_impl)

def exec_dependency_labels_tests():
    return unittest.suite(
        "exec_dependency_labels_tests",
        matching_features_and_single_resolution_test,
        split_propagates_to_normal_ancestors_test,
        disjoint_platforms_can_share_definition_test,
        renamed_dependencies_require_distinct_definitions_test,
        different_dependency_sets_require_distinct_definitions_test,
        normal_and_build_aliases_are_compared_separately_test,
    )
