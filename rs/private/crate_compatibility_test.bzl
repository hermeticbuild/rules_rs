"""Crate compatibility test."""

load("@bazel_skylib//lib:unittest.bzl", "asserts", "unittest")
load("//rs/private:crate_coalescing.bzl", "coalesce_spoke")
load("//rs/private:crate_compatibility.bzl", "compilation_fingerprint", "merge_compilation_fingerprints", "validate_compilation_fingerprint")
load("//rs/private:crate_identity.bzl", "canonical_git_repo", "package_identity")
load("//rs/private:crate_metadata.bzl", "git_checkout_fingerprint")
load("//rs/private:crate_test_fixtures.bzl", _GIT = "GIT", _annotation = "annotation", _coalescer = "coalescer", _crate_kwargs = "crate_kwargs", _expect_failure = "expect_failure", _fingerprint = "fingerprint", _package = "package", _repository_kwargs = "repository_kwargs")

def _identical_and_additive_fingerprints_merge_impl(ctx):
    env = unittest.begin(ctx)
    dep_a = "@repo_a//:dep_a"
    dep_b = "@repo_b//:dep_b"
    first = _fingerprint(
        features = ["base", "a"],
        features_select = {"linux": ["platform_a"]},
        gen_binaries = ["tool_a"],
        deps_select = {"linux": [dep_a]},
        aliases = {dep_a: "dep_a"},
    )
    identical = merge_compilation_fingerprints(first, first)
    asserts.true(env, identical != None)
    asserts.equals(env, ["a", "base"], identical["union"]["crate_features"])
    asserts.equals(env, identical, merge_compilation_fingerprints(identical, identical))
    merged = merge_compilation_fingerprints(first, _fingerprint(
        features = ["base", "b", "b"],
        features_select = {"linux": ["platform_b"], "macos": ["mac"]},
        gen_binaries = ["tool_b", "tool_b"],
        build_deps_select = {"linux": [dep_b]},
        aliases = {dep_b: "dep_b"},
    ))
    asserts.true(env, merged != None)
    asserts.equals(env, ["a", "b", "base"], merged["union"]["crate_features"])
    asserts.equals(env, ["platform_a", "platform_b"], merged["union"]["crate_features_select"]["linux"])
    asserts.equals(env, ["mac"], merged["union"]["crate_features_select"]["macos"])
    asserts.equals(env, ["tool_a", "tool_b"], merged["union"]["gen_binaries"])
    asserts.equals(env, [dep_a], merged["union"]["deps_select"]["linux"])
    asserts.equals(env, [dep_b], merged["union"]["build_script_deps_select"]["linux"])
    return unittest.end(env)

def _selected_direct_dependency_is_not_repeated_impl(ctx):
    env = unittest.begin(ctx)
    dep = "@repo//:dep"
    merged = merge_compilation_fingerprints(
        _fingerprint(deps = [dep], deps_select = {"linux": [dep]}),
        _fingerprint(deps = [dep], deps_select = {"linux": [dep]}),
    )
    asserts.true(env, merged != None)
    asserts.equals(env, [], merged["union"]["deps_select"]["linux"])
    return unittest.end(env)

def _alias_compatibility_is_validated_impl(ctx):
    env = unittest.begin(ctx)
    dep_a = "@a//:dep_a"
    dep_b = "@b//:dep_b"
    preserving = merge_compilation_fingerprints(
        _fingerprint(deps_select = {"linux": [dep_a]}, aliases = {dep_a: "renamed"}),
        _fingerprint(deps_select = {"linux": [dep_a]}, aliases = {dep_a: "renamed", "@unused//:x": "unused"}),
    )
    asserts.true(env, preserving != None)
    changed_name = merge_compilation_fingerprints(
        _fingerprint(deps_select = {"linux": [dep_a]}, aliases = {dep_a: "first"}),
        _fingerprint(deps_select = {"linux": [dep_a]}, aliases = {dep_a: "second"}),
    )
    asserts.equals(env, None, changed_name)
    duplicate_name = merge_compilation_fingerprints(
        _fingerprint(deps_select = {"linux": [dep_a]}, aliases = {dep_a: "same"}),
        _fingerprint(deps_select = {"linux": [dep_b]}, aliases = {dep_b: "same"}),
    )
    asserts.equals(env, None, duplicate_name)
    return unittest.end(env)

def _normal_and_build_action_collisions_are_rejected_impl(ctx):
    env = unittest.begin(ctx)
    direct = "@direct//:one"
    selected = "@selected//:two"
    aliases = {direct: "collision", selected: "collision"}
    for direct_key in ["normal", "build"]:
        if direct_key == "normal":
            first = _fingerprint(deps = [direct], aliases = aliases)
            second = _fingerprint(deps = [direct], deps_select = {"linux": [selected]}, aliases = aliases)
        else:
            first = _fingerprint(build_deps = [direct], aliases = aliases)
            second = _fingerprint(build_deps = [direct], build_deps_select = {"linux": [selected]}, aliases = aliases)
        asserts.equals(env, None, merge_compilation_fingerprints(first, second))
    return unittest.end(env)

def _nonadditive_inputs_split_impl(ctx):
    env = unittest.begin(ctx)
    base = _fingerprint()
    changed = [
        _fingerprint(patches = ["//:patch"]),
        _fingerprint(patch_args = ["-p1"]),
        _fingerprint(patch_tool = "custom"),
        _fingerprint(additive_build_file_content = "filegroup(name='extra')"),
        _fingerprint(action = {"rustc_flags": ["--cfg=changed"]}),
        _fingerprint(action = {"build_script_env": {"KEY": "value"}}),
        _fingerprint(action = {"build_script_data": ["//:input"]}),
        _fingerprint(action = {"crate_tags": ["tag"]}),
        _fingerprint(action = {"use_legacy_rules_rust_platforms": True}),
    ]
    for fingerprint in changed:
        asserts.equals(env, None, merge_compilation_fingerprints(base, fingerprint))
    merged_platforms = merge_compilation_fingerprints(
        _fingerprint(platforms = ["linux", "macos", "linux"]),
        _fingerprint(platforms = ["windows", "linux"]),
    )
    asserts.true(env, merged_platforms != None)
    asserts.equals(env, ["linux", "macos", "windows"], merged_platforms["union"]["platform_triples"])
    return unittest.end(env)

def _identical_annotation_values_permit_coalescing_impl(ctx):
    env = unittest.begin(ctx)
    package = _package()
    coalescer = _coalescer()
    first = _fingerprint(action = {
        "build_script_env_files": ["//:env"],
        "link_deps": ["native_foo"],
    })
    identical = _fingerprint(action = {
        "build_script_env_files": ["//:env"],
        "link_deps": ["native_foo"],
    })
    asserts.true(env, merge_compilation_fingerprints(first, identical) != None)
    first_class = coalesce_spoke(coalescer, package, "", "first", first)[1]
    second_class = coalesce_spoke(coalescer, package, "", "second", identical)[1]
    asserts.equals(env, 0, first_class)
    asserts.equals(env, 0, second_class)
    asserts.equals(env, 1, len(coalescer["packages"][package_identity(package)]["classes"]))
    return unittest.end(env)

def _different_build_script_env_files_split_impl(ctx):
    env = unittest.begin(ctx)
    package = _package()
    coalescer = _coalescer()
    first = _fingerprint(action = {"build_script_env_files": ["//:env_a"]})
    second = _fingerprint(action = {"build_script_env_files": ["//:env_b"]})
    asserts.equals(env, None, merge_compilation_fingerprints(first, second))
    first_class = coalesce_spoke(coalescer, package, "", "first", first)[1]
    second_class = coalesce_spoke(coalescer, package, "", "second", second)[1]
    asserts.true(env, first_class != second_class)
    asserts.equals(env, 2, len(coalescer["packages"][package_identity(package)]["classes"]))
    return unittest.end(env)

def _different_link_deps_split_impl(ctx):
    env = unittest.begin(ctx)
    package = _package()
    coalescer = _coalescer()
    first = _fingerprint(action = {"link_deps": ["native_foo"]})
    second = _fingerprint(action = {"link_deps": ["native_bar"]})
    asserts.equals(env, None, merge_compilation_fingerprints(first, second))
    first_class = coalesce_spoke(coalescer, package, "", "first", first)[1]
    second_class = coalesce_spoke(coalescer, package, "", "second", second)[1]
    asserts.true(env, first_class != second_class)
    asserts.equals(env, 2, len(coalescer["packages"][package_identity(package)]["classes"]))
    return unittest.end(env)

def _git_checkout_and_compilation_inputs_impl(ctx):
    env = unittest.begin(ctx)
    package = _package(source = _GIT)
    first = _annotation(patches = [Label("//:first.patch")], workspace_cargo_toml = "first/Cargo.toml")
    second = _annotation(patch_args = ["-p1"], patch_tool = "patch", patches = [Label("//:second.patch")], workspace_cargo_toml = "second/Cargo.toml")
    kwargs = _repository_kwargs(_fingerprint())
    asserts.true(env, compilation_fingerprint(package, first, kwargs, ["linux"]) != compilation_fingerprint(package, second, kwargs, ["linux"]))
    asserts.true(env, git_checkout_fingerprint(first) != git_checkout_fingerprint(second))
    asserts.true(env, canonical_git_repo("https://example.com/repo", "commit", git_checkout_fingerprint(first)) != canonical_git_repo("https://example.com/repo", "commit", git_checkout_fingerprint(second)))
    return unittest.end(env)

def _unknown_compatibility_input_subject_impl(_ctx):
    fingerprint = _fingerprint()
    fingerprint["union"]["future_repository_attr"] = []
    validate_compilation_fingerprint(fingerprint)
    return []

def _missing_compatibility_input_subject_impl(_ctx):
    fingerprint = _fingerprint()
    fingerprint["exact"]["crate_rule"].pop("rustc_flags")
    validate_compilation_fingerprint(fingerprint)
    return []

def _undecided_annotation_policy_subject_impl(_ctx):
    fingerprint = _fingerprint(action = {
        "build_script_env_files": ["//:env"],
        "link_deps": ["native_foo"],
    })
    kwargs = _crate_kwargs(fingerprint)
    kwargs["future_annotation_attr"] = []
    compilation_fingerprint(
        _package(),
        _annotation(),
        kwargs,
        ["x86_64-unknown-linux-gnu"],
    )
    return []

unknown_compatibility_input_subject = rule(implementation = _unknown_compatibility_input_subject_impl)

_unknown_compatibility_input_subject = unknown_compatibility_input_subject

missing_compatibility_input_subject = rule(implementation = _missing_compatibility_input_subject_impl)

_missing_compatibility_input_subject = missing_compatibility_input_subject

undecided_annotation_policy_subject = rule(implementation = _undecided_annotation_policy_subject_impl)

_undecided_annotation_policy_subject = undecided_annotation_policy_subject

identical_and_additive_fingerprints_merge_test = unittest.make(_identical_and_additive_fingerprints_merge_impl)

selected_direct_dependency_is_not_repeated_test = unittest.make(_selected_direct_dependency_is_not_repeated_impl)

alias_compatibility_is_validated_test = unittest.make(_alias_compatibility_is_validated_impl)

normal_and_build_action_collisions_are_rejected_test = unittest.make(_normal_and_build_action_collisions_are_rejected_impl)

nonadditive_inputs_split_test = unittest.make(_nonadditive_inputs_split_impl)

identical_annotation_values_permit_coalescing_test = unittest.make(_identical_annotation_values_permit_coalescing_impl)

different_build_script_env_files_split_test = unittest.make(_different_build_script_env_files_split_impl)

different_link_deps_split_test = unittest.make(_different_link_deps_split_impl)

git_checkout_and_compilation_inputs_test = unittest.make(_git_checkout_and_compilation_inputs_impl)

unknown_compatibility_input_fails_test = _expect_failure("compatibility schema union keys must be")

missing_compatibility_input_fails_test = _expect_failure("compatibility schema exact.crate_rule keys must be")

undecided_annotation_policy_fails_test = _expect_failure("coalesced crate kwargs must classify every rust_crate attr")
