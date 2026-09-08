"""Crate coalescer test."""

load("@bazel_skylib//lib:unittest.bzl", "asserts", "unittest")
load("//rs/private:crate_coalescing.bzl", "coalesce_spoke", "coalesced_compilation_fingerprint", "coalesced_compilation_kwargs", "finalize_coalescer")
load("//rs/private:crate_compatibility.bzl", "merge_compilation_fingerprints")
load("//rs/private:crate_identity.bzl", "canonical_spoke_repo", "package_identity")
load("//rs/private:crate_test_fixtures.bzl", _active_targets = "active_targets", _assert_valid_merged_action = "assert_valid_merged_action", _coalescer = "coalescer", _expect_failure = "expect_failure", _extern_name = "extern_name", _fingerprint = "fingerprint", _package = "package")

def _additive_dependency_respects_receiving_hub_class_impl(ctx):
    env = unittest.begin(ctx)
    coalescer = _coalescer()
    rayon = _package(name = "rayon")
    hashbrown = _package(name = "hashbrown")

    rayon_a_repo, _, _ = coalesce_spoke(
        coalescer,
        rayon,
        "",
        "hub_a",
        _fingerprint(deps = ["@either_16//:either"]),
    )
    rayon_b_repo, _, _ = coalesce_spoke(
        coalescer,
        rayon,
        "",
        "hub_b",
        _fingerprint(deps = ["@either_15//:either"]),
    )
    asserts.true(env, rayon_a_repo != rayon_b_repo)

    hashbrown_a_class = coalesce_spoke(
        coalescer,
        hashbrown,
        "",
        "hub_a",
        _fingerprint(deps_select = {
            "x86_64-unknown-linux-gnu": ["@%s//:rayon" % rayon_a_repo],
        }),
    )[1]
    hashbrown_b_class = coalesce_spoke(
        coalescer,
        hashbrown,
        "",
        "hub_b",
        _fingerprint(),
    )[1]

    # Reusing hub A's hashbrown class would add its optional rayon edge to hub
    # B, even though hub B assigned that Cargo identity to a different class.
    asserts.true(env, hashbrown_a_class != hashbrown_b_class)
    return unittest.end(env)

def _additive_dependency_accepts_same_receiving_hub_class_impl(ctx):
    env = unittest.begin(ctx)
    coalescer = _coalescer()
    rayon = _package(name = "rayon")
    hashbrown = _package(name = "hashbrown")
    rayon_repo = coalesce_spoke(coalescer, rayon, "", "hub_a", _fingerprint())[0]
    asserts.equals(env, rayon_repo, coalesce_spoke(coalescer, rayon, "", "hub_b", _fingerprint())[0])

    first_class = coalesce_spoke(
        coalescer,
        hashbrown,
        "",
        "hub_a",
        _fingerprint(deps_select = {"x86_64-unknown-linux-gnu": ["@%s//:rayon" % rayon_repo]}),
    )[1]
    second_class = coalesce_spoke(coalescer, hashbrown, "", "hub_b", _fingerprint())[1]
    asserts.equals(env, first_class, second_class)
    return unittest.end(env)

def _additive_dependency_allows_disjoint_platform_class_impl(ctx):
    env = unittest.begin(ctx)
    coalescer = _coalescer()
    rayon = _package(name = "rayon")
    hashbrown = _package(name = "hashbrown")
    linux = "x86_64-unknown-linux-gnu"
    windows = "x86_64-pc-windows-gnullvm"
    rayon_a_repo = coalesce_spoke(coalescer, rayon, "", "hub_a", _fingerprint(deps = ["@either_16//:either"], platforms = [linux]))[0]
    coalesce_spoke(coalescer, rayon, "", "hub_b", _fingerprint(deps = ["@either_15//:either"], platforms = [windows]))

    first_class = coalesce_spoke(
        coalescer,
        hashbrown,
        "",
        "hub_a",
        _fingerprint(deps_select = {linux: ["@%s//:rayon" % rayon_a_repo]}, platforms = [linux]),
    )[1]
    second_class = coalesce_spoke(coalescer, hashbrown, "", "hub_b", _fingerprint(platforms = [windows]))[1]
    asserts.equals(env, first_class, second_class)
    return unittest.end(env)

def _additive_dependency_checks_every_existing_hub_impl(ctx):
    env = unittest.begin(ctx)
    coalescer = _coalescer()
    rayon = _package(name = "rayon")
    hashbrown = _package(name = "hashbrown")
    rayon_a_repo = coalesce_spoke(coalescer, rayon, "", "hub_a", _fingerprint(deps = ["@either_16//:either"]))[0]
    rayon_b_repo = coalesce_spoke(coalescer, rayon, "", "hub_b", _fingerprint(deps = ["@either_15//:either"]))[0]
    asserts.equals(env, rayon_b_repo, coalesce_spoke(coalescer, rayon, "", "hub_c", _fingerprint(deps = ["@either_15//:either"]))[0])

    shared_class = coalesce_spoke(coalescer, hashbrown, "", "hub_a", _fingerprint())[1]
    asserts.equals(env, shared_class, coalesce_spoke(coalescer, hashbrown, "", "hub_b", _fingerprint())[1])
    third_class = coalesce_spoke(
        coalescer,
        hashbrown,
        "",
        "hub_c",
        _fingerprint(deps_select = {"x86_64-unknown-linux-gnu": ["@%s//:rayon" % rayon_b_repo]}),
    )[1]
    asserts.true(env, shared_class != third_class)
    asserts.true(env, rayon_a_repo != rayon_b_repo)
    return unittest.end(env)

def _multiple_compatibility_classes_compare_every_class_impl(ctx):
    env = unittest.begin(ctx)
    package = _package()
    for hubs in [["a", "b1", "b2"], ["a", "b2", "b1"]]:
        coalescer = _coalescer()
        assignments = {}
        assignments["a"] = coalesce_spoke(coalescer, package, "", "a", _fingerprint(action = {"rustc_flags": ["--cfg=a"]}))[1]
        for hub in hubs[1:]:
            feature = "x" if hub == "b1" else "y"
            assignments[hub] = coalesce_spoke(
                coalescer,
                package,
                "",
                hub,
                _fingerprint(features = [feature], action = {"rustc_flags": ["--cfg=b"]}),
            )[1]
        asserts.equals(env, 0, assignments["a"])
        asserts.equals(env, 1, assignments["b1"])
        asserts.equals(env, 1, assignments["b2"])
        asserts.equals(env, 2, len(coalescer["packages"][package_identity(package)]["classes"]))
        merged = coalescer["packages"][package_identity(package)]["classes"][1]["fingerprint"]
        asserts.equals(env, ["x", "y"], merged["union"]["crate_features"])
    return unittest.end(env)

def _class_assignments_are_semantically_permutation_invariant_impl(ctx):
    env = unittest.begin(ctx)
    package = _package()
    occurrences = {
        "a": _fingerprint(features = ["a"], action = {"rustc_flags": ["--cfg=a"]}),
        "b1": _fingerprint(features = ["x"], action = {"rustc_flags": ["--cfg=b"]}),
        "b2": _fingerprint(features = ["y"], action = {"rustc_flags": ["--cfg=b"]}),
    }
    for order in [["a", "b1", "b2"], ["b1", "a", "b2"], ["b2", "b1", "a"]]:
        coalescer = _coalescer()
        classes = {}
        for hub in order:
            classes[hub] = coalesce_spoke(coalescer, package, "", hub, occurrences[hub])[1]
        asserts.true(env, classes["a"] != classes["b1"])
        asserts.equals(env, classes["b1"], classes["b2"])
        merged = coalescer["packages"][package_identity(package)]["classes"][classes["b1"]]["fingerprint"]
        asserts.equals(env, ["x", "y"], merged["union"]["crate_features"])
    return unittest.end(env)

def _finalize_materializes_one_repository_once_impl(ctx):
    env = unittest.begin(ctx)
    coalescer = _coalescer()
    package = _package()
    first_fingerprint = _fingerprint(features = ["shared"], platforms = ["linux"])
    second_fingerprint = _fingerprint(features = ["shared"], platforms = ["macos", "windows"])
    first_repo = coalesce_spoke(coalescer, package, "", "first", first_fingerprint)[0]
    second_repo = coalesce_spoke(coalescer, package, "", "second", second_fingerprint)[0]
    asserts.equals(env, first_repo, second_repo)
    finalize_coalescer(coalescer)
    first_create = coalesce_spoke(coalescer, package, "", "first", first_fingerprint)
    second_create = coalesce_spoke(coalescer, package, "", "second", second_fingerprint)
    asserts.true(env, first_create[2])
    asserts.false(env, second_create[2])
    finalized = coalesced_compilation_fingerprint(coalescer, package, "", "first", {})
    asserts.equals(env, ["linux", "macos", "windows"], finalized["union"]["platform_triples"])
    kwargs = coalesced_compilation_kwargs(coalescer, package, "", "first", {"hub_name": "first"})
    asserts.equals(env, "first", kwargs["hub_name"])
    asserts.equals(env, ["linux", "macos", "windows"], kwargs["platform_triples"])
    return unittest.end(env)

def _valid_fingerprint_property_impl(ctx):
    env = unittest.begin(ctx)
    for seed in range(64):
        first_target = "@repo//:dep_%d" % (seed % 11)
        second_target = "@repo//:dep_%d" % ((seed * 7 + 3) % 11)
        first_alias = "first_%d" % seed
        second_alias = first_alias if first_target == second_target else "second_%d" % seed
        first = _fingerprint(
            features = ["common", "feature_%d" % (seed % 5)],
            features_select = {"linux": ["linux_%d" % (seed % 3)]},
            deps_select = {"linux": [first_target]},
            aliases = {first_target: first_alias},
        )
        second = _fingerprint(
            features = ["common", "feature_%d" % ((seed + 1) % 5)],
            features_select = {"linux": ["linux_%d" % ((seed + 1) % 3)]},
            deps_select = {"linux": [second_target]},
            aliases = {second_target: second_alias},
        )
        merged = merge_compilation_fingerprints(first, second)
        asserts.true(env, merged != None)
        for original in [first, second]:
            for action in [("deps", "deps_select"), ("build_script_deps", "build_script_deps_select")]:
                original_targets = _active_targets(original, action[0], action[1])
                merged_targets = _active_targets(merged, action[0], action[1])
                for target in original_targets:
                    asserts.true(env, target in merged_targets)
                    asserts.equals(
                        env,
                        _extern_name(target, original["union"]["aliases"]),
                        _extern_name(target, merged["union"]["aliases"]),
                    )
            for feature in original["union"]["crate_features"]:
                asserts.true(env, feature in merged["union"]["crate_features"])
            for triple, features in original["union"]["crate_features_select"].items():
                for feature in features:
                    asserts.true(env, feature in merged["union"]["crate_features_select"][triple])
        _assert_valid_merged_action(env, merged, "deps", "deps_select")
        _assert_valid_merged_action(env, merged, "build_script_deps", "build_script_deps_select")
    return unittest.end(env)

def _checksum_conflict_subject_impl(_ctx):
    coalescer = _coalescer()
    coalesce_spoke(coalescer, _package(checksum = "first"), "", "first_hub", _fingerprint())
    coalesce_spoke(coalescer, _package(checksum = "second"), "", "second_hub", _fingerprint())
    return []

def _canonical_repository_collision_subject_impl(_ctx):
    coalescer = _coalescer()
    package = _package()
    coalescer["identities_by_repo"][canonical_spoke_repo(package)] = "different identity"
    coalesce_spoke(coalescer, package, "", "hub", _fingerprint())
    return []

def _finalize_twice_subject_impl(_ctx):
    coalescer = _coalescer()
    finalize_coalescer(coalescer)
    finalize_coalescer(coalescer)
    return []

def _missing_finalized_assignment_subject_impl(_ctx):
    coalescer = _coalescer()
    finalize_coalescer(coalescer)
    coalesced_compilation_fingerprint(coalescer, _package(), "", "missing", {})
    return []

checksum_conflict_subject = rule(implementation = _checksum_conflict_subject_impl)

_checksum_conflict_subject = checksum_conflict_subject

canonical_repository_collision_subject = rule(implementation = _canonical_repository_collision_subject_impl)

_canonical_repository_collision_subject = canonical_repository_collision_subject

finalize_twice_subject = rule(implementation = _finalize_twice_subject_impl)

_finalize_twice_subject = finalize_twice_subject

missing_finalized_assignment_subject = rule(implementation = _missing_finalized_assignment_subject_impl)

_missing_finalized_assignment_subject = missing_finalized_assignment_subject

additive_dependency_respects_receiving_hub_class_test = unittest.make(_additive_dependency_respects_receiving_hub_class_impl)

additive_dependency_accepts_same_receiving_hub_class_test = unittest.make(_additive_dependency_accepts_same_receiving_hub_class_impl)

additive_dependency_allows_disjoint_platform_class_test = unittest.make(_additive_dependency_allows_disjoint_platform_class_impl)

additive_dependency_checks_every_existing_hub_test = unittest.make(_additive_dependency_checks_every_existing_hub_impl)

multiple_compatibility_classes_compare_every_class_test = unittest.make(_multiple_compatibility_classes_compare_every_class_impl)

class_assignments_are_semantically_permutation_invariant_test = unittest.make(_class_assignments_are_semantically_permutation_invariant_impl)

finalize_materializes_one_repository_once_test = unittest.make(_finalize_materializes_one_repository_once_impl)

valid_fingerprint_property_test = unittest.make(_valid_fingerprint_property_impl)

checksum_conflict_fails_test = _expect_failure("Conflicting Cargo registry checksums")

canonical_repository_collision_fails_test = _expect_failure("encode to the same canonical repository")

finalize_twice_fails_test = _expect_failure("Cannot finalize a crate coalescer more than once")

missing_finalized_assignment_fails_test = _expect_failure("Missing finalized crate coalescing assignment")
