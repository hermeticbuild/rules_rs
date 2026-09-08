"""Crate weak features test."""

load("@bazel_skylib//lib:unittest.bzl", "asserts", "unittest")
load("//rs/private:crate_compatibility.bzl", "has_weak_dependency_features", "merge_compilation_fingerprints", "weak_dependency_feature_requests")
load("//rs/private:crate_test_fixtures.bzl", _fingerprint = "fingerprint")

def _weak_features_reject_only_cross_terms_impl(ctx):
    env = unittest.begin(ctx)
    linux = "x86_64-unknown-linux-gnu"
    request = json.encode(["child", "serde", ["bridge"]])
    dormant = _fingerprint(weak = True, weak_requests = [request], features = ["bridge"])
    activation_only = _fingerprint(
        weak = True,
        weak_requests = [request],
        features = ["dep:child"],
        deps_select = {linux: ["@child//:child"]},
    )
    already_live = _fingerprint(
        weak = True,
        weak_requests = [request],
        features = ["bridge", "dep:child"],
        deps_select = {linux: ["@child//:child"]},
    )
    unrelated_difference = _fingerprint(
        weak = True,
        weak_requests = [request],
        features = ["bridge", "extra"],
    )
    asserts.equals(env, None, merge_compilation_fingerprints(dormant, activation_only))
    asserts.true(env, merge_compilation_fingerprints(dormant, already_live) != None)
    asserts.true(env, merge_compilation_fingerprints(dormant, unrelated_difference) != None)
    return unittest.end(env)

def _weak_features_merge_rustix_shape_impl(ctx):
    env = unittest.begin(ctx)
    request = json.encode(["libc", "std", ["std"]])
    small = _fingerprint(
        weak = True,
        weak_requests = [request],
        features = ["alloc", "std"],
    )
    rich = _fingerprint(
        weak = True,
        weak_requests = [request],
        features = ["alloc", "event", "fs", "std", "dep:libc"],
    )
    merged = merge_compilation_fingerprints(small, rich)
    asserts.true(env, merged != None)
    asserts.equals(env, ["alloc", "dep:libc", "event", "fs", "std"], merged["union"]["crate_features"])
    return unittest.end(env)

def _feature_sensitive_dependencies_require_identical_features_impl(ctx):
    env = unittest.begin(ctx)
    base = _fingerprint(feature_sensitive = True, features = ["base"])
    additive_dep = _fingerprint(
        feature_sensitive = True,
        features = ["base"],
        deps_select = {"x86_64-unknown-linux-gnu": ["@child//:child"]},
    )
    different_features = _fingerprint(feature_sensitive = True, features = ["base", "edge"])
    asserts.true(env, merge_compilation_fingerprints(base, additive_dep) != None)
    asserts.equals(env, None, merge_compilation_fingerprints(base, different_features))
    return unittest.end(env)

def _weak_features_merge_disjoint_domains_without_leaking_impl(ctx):
    env = unittest.begin(ctx)
    linux_dep = "@linux//:dep"
    windows_build_dep = "@windows//:build_dep"
    merged = merge_compilation_fingerprints(
        _fingerprint(
            weak = True,
            platforms = ["linux"],
            features = ["linux_feature"],
            deps = [linux_dep],
        ),
        _fingerprint(
            weak = True,
            platforms = ["windows"],
            features = ["windows_feature"],
            build_deps = [windows_build_dep],
        ),
    )
    asserts.true(env, merged != None)
    asserts.equals(env, [], merged["union"]["crate_features"])
    asserts.equals(env, {"linux": ["linux_feature"], "windows": ["windows_feature"]}, merged["union"]["crate_features_select"])
    asserts.equals(env, [], merged["exact"]["crate_rule"]["deps"])
    asserts.equals(env, {"linux": [linux_dep]}, merged["union"]["deps_select"])
    asserts.equals(env, [], merged["exact"]["crate_rule"]["build_script_deps"])
    asserts.equals(env, {"windows": [windows_build_dep]}, merged["union"]["build_script_deps_select"])
    return unittest.end(env)

def _weak_features_compare_effective_not_encoded_closures_impl(ctx):
    env = unittest.begin(ctx)
    dep = "@repo//:dep"
    merged = merge_compilation_fingerprints(
        _fingerprint(
            weak = True,
            platforms = ["linux", "windows"],
            features = ["same"],
            deps = [dep],
        ),
        _fingerprint(
            weak = True,
            platforms = ["linux", "windows"],
            features_select = {"linux": ["same"], "windows": ["same"]},
            deps_select = {"linux": [dep], "windows": [dep]},
        ),
    )
    asserts.true(env, merged != None)
    asserts.equals(env, ["same"], merged["union"]["crate_features"])
    asserts.equals(env, {}, merged["union"]["crate_features_select"])
    asserts.equals(env, [dep], merged["exact"]["crate_rule"]["deps"])
    asserts.equals(env, {}, merged["union"]["deps_select"])
    return unittest.end(env)

def _weak_features_ignore_additive_outputs_impl(ctx):
    env = unittest.begin(ctx)
    merged = merge_compilation_fingerprints(
        _fingerprint(weak = True, features = ["same"], gen_binaries = ["first"]),
        _fingerprint(weak = True, features = ["same"], gen_binaries = ["second"]),
    )
    asserts.true(env, merged != None)
    asserts.equals(env, ["first", "second"], merged["union"]["gen_binaries"])
    return unittest.end(env)

def _weak_features_still_reject_alias_collisions_impl(ctx):
    env = unittest.begin(ctx)
    dep_a = "@a//:dep"
    dep_b = "@b//:dep"
    fingerprint = _fingerprint(
        weak = True,
        deps = [dep_a, dep_b],
        aliases = {dep_a: "same", dep_b: "same"},
    )
    asserts.equals(env, None, merge_compilation_fingerprints(fingerprint, fingerprint))
    return unittest.end(env)

def _weak_features_use_effective_legacy_domains_impl(ctx):
    env = unittest.begin(ctx)
    merged = merge_compilation_fingerprints(
        _fingerprint(
            weak = True,
            platforms = ["x86_64-unknown-linux-musl"],
            features = ["same"],
            action = {"use_legacy_rules_rust_platforms": True},
        ),
        _fingerprint(
            weak = True,
            platforms = ["x86_64-unknown-linux-gnu"],
            features_select = {"x86_64-unknown-linux-gnu": ["same"]},
            action = {"use_legacy_rules_rust_platforms": True},
        ),
    )
    asserts.true(env, merged != None)
    asserts.equals(env, ["same"], merged["union"]["crate_features"])
    asserts.equals(env, {}, merged["union"]["crate_features_select"])
    return unittest.end(env)

def _weak_feature_detection_impl(ctx):
    env = unittest.begin(ctx)
    asserts.true(env, has_weak_dependency_features({"features": {"feature": ["foo?/bar"]}}))
    asserts.false(env, has_weak_dependency_features({"features": {"feature": ["foo/bar", "dep:foo"]}}))
    asserts.false(env, has_weak_dependency_features({}))
    asserts.equals(
        env,
        [json.encode(["foo", "serde", ["first", "second"]])],
        weak_dependency_feature_requests({"features": {
            "second": ["foo?/serde"],
            "first": ["foo?/serde", "bar/baz"],
        }}),
    )
    return unittest.end(env)

weak_features_reject_only_cross_terms_test = unittest.make(_weak_features_reject_only_cross_terms_impl)

weak_features_merge_rustix_shape_test = unittest.make(_weak_features_merge_rustix_shape_impl)

feature_sensitive_dependencies_require_identical_features_test = unittest.make(_feature_sensitive_dependencies_require_identical_features_impl)

weak_features_merge_disjoint_domains_without_leaking_test = unittest.make(_weak_features_merge_disjoint_domains_without_leaking_impl)

weak_features_compare_effective_not_encoded_closures_test = unittest.make(_weak_features_compare_effective_not_encoded_closures_impl)

weak_features_ignore_additive_outputs_test = unittest.make(_weak_features_ignore_additive_outputs_impl)

weak_features_still_reject_alias_collisions_test = unittest.make(_weak_features_still_reject_alias_collisions_impl)

weak_features_use_effective_legacy_domains_test = unittest.make(_weak_features_use_effective_legacy_domains_impl)

weak_feature_detection_test = unittest.make(_weak_feature_detection_impl)
