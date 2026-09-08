"""Crate metadata test."""

load("@bazel_skylib//lib:unittest.bzl", "asserts", "unittest")
load("//rs/private:crate_metadata.bzl", "add_git_build_file", "add_registry_fetch_config", "git_fact_key", "record_hub_config", "registry_fact_key", "registry_metadata_prefixes", "selected_registry_credentials")
load("//rs/private:crate_test_fixtures.bzl", _GIT = "GIT", _OTHER_REGISTRY = "OTHER_REGISTRY", _REGISTRY = "REGISTRY", _annotation = "annotation", _expect_failure = "expect_failure")

def _registry_metadata_prefixes_are_order_independent_impl(ctx):
    env = unittest.begin(ctx)
    first = {_REGISTRY: {}, _OTHER_REGISTRY: {}}
    reversed_configs = {_OTHER_REGISTRY: {}, _REGISTRY: {}}
    one_registry = {_REGISTRY: {}}
    asserts.equals(
        env,
        registry_metadata_prefixes(first),
        registry_metadata_prefixes(reversed_configs),
    )
    two = registry_metadata_prefixes(first)
    asserts.equals(
        env,
        {s: "registry_metadata_%d" % i for i, s in enumerate(sorted(first))},
        two,
    )
    asserts.true(env, len(set(two.values())) == 2, "distinct sources get distinct prefixes")
    asserts.equals(
        env,
        {"sparse+https://index.crates.io/": "registry_metadata_0"},
        registry_metadata_prefixes(one_registry),
    )
    return unittest.end(env)

def _fact_keys_are_schema_qualified_impl(ctx):
    env = unittest.begin(ctx)
    registry = registry_fact_key(_REGISTRY, "crate", "1.0.0")
    asserts.true(env, registry.startswith("rs_crate_fact_v2_registry_"))
    for key in [
        registry_fact_key(_OTHER_REGISTRY, "crate", "1.0.0"),
        registry_fact_key(_REGISTRY, "other", "1.0.0"),
        registry_fact_key(_REGISTRY, "crate", "2.0.0"),
    ]:
        asserts.true(env, registry != key)

    annotation = _annotation()
    git = git_fact_key(_GIT, "crate", "1.0.0", annotation, "member")
    asserts.true(env, git.startswith("rs_crate_fact_v2_git_"))
    for key in [
        git_fact_key("git+https://other.example/repo#0123456789abcdef", "crate", "1.0.0", annotation, "member"),
        git_fact_key(_GIT, "crate", "2.0.0", annotation, "member"),
        git_fact_key(_GIT, "crate", "1.0.0", _annotation(patches = [Label("//:patch")]), "member"),
        git_fact_key(_GIT, "crate", "1.0.0", _annotation(workspace_cargo_toml = "nested/Cargo.toml"), "member"),
        git_fact_key(_GIT, "crate", "1.0.0", annotation, "other"),
    ]:
        asserts.true(env, git != key)
    return unittest.end(env)

def _registry_fetch_selection_remains_deterministic_impl(ctx):
    env = unittest.begin(ctx)
    first = {}
    second = {}
    source = "sparse+https://private.example.com/index/"
    add_registry_fetch_config(first, "anonymous", source, None, False, {})
    add_registry_fetch_config(first, "authenticated", source, Label("//:cargo-config.toml"), True, {source: "secret"})
    add_registry_fetch_config(second, "authenticated", source, Label("//:cargo-config.toml"), True, {source: "secret"})
    add_registry_fetch_config(second, "anonymous", source, None, False, {})
    asserts.equals(env, first, second)
    asserts.equals(env, "authenticated", first[source]["hub_name"])
    first[source]["auth_required"] = True
    asserts.equals(env, {source: "secret"}, selected_registry_credentials(first))

    first[source]["auth_required"] = False
    asserts.equals(env, {}, selected_registry_credentials(first))

    public = {}
    add_registry_fetch_config(public, "z_hub", _REGISTRY, None, False, {})
    add_registry_fetch_config(public, "a_hub", _REGISTRY, None, False, {})
    add_registry_fetch_config(public, "other", _OTHER_REGISTRY, None, False, {})
    asserts.equals(env, "a_hub", public[_REGISTRY]["hub_name"])
    asserts.equals(env, 2, len(public))
    return unittest.end(env)

def _duplicate_hub_name_subject_impl(_ctx):
    configs = {}
    record_hub_config(configs, struct(name = "same_hub"), struct(name = "first"))
    record_hub_config(configs, struct(name = "same_hub"), struct(name = "second"))
    return []

def _incompatible_git_overlay_subject_impl(_ctx):
    git_repo = {"build_files": {}, "first_hub": "first_hub"}
    add_git_build_file(git_repo, _GIT, "BUILD.bazel", "first", "first_hub")
    add_git_build_file(git_repo, _GIT, "BUILD.bazel", "second", "second_hub")
    return []

def _conflicting_registry_credentials_subject_impl(_ctx):
    configs = {}
    source = "sparse+https://private.example.com/index/"
    add_registry_fetch_config(configs, "first", source, Label("//:first.toml"), True, {source: "first"})
    add_registry_fetch_config(configs, "second", source, Label("//:second.toml"), True, {source: "second"})
    return []

duplicate_hub_name_subject = rule(implementation = _duplicate_hub_name_subject_impl)

_duplicate_hub_name_subject = duplicate_hub_name_subject

incompatible_git_overlay_subject = rule(implementation = _incompatible_git_overlay_subject_impl)

_incompatible_git_overlay_subject = incompatible_git_overlay_subject

conflicting_registry_credentials_subject = rule(implementation = _conflicting_registry_credentials_subject_impl)

_conflicting_registry_credentials_subject = conflicting_registry_credentials_subject

registry_metadata_prefixes_are_order_independent_test = unittest.make(_registry_metadata_prefixes_are_order_independent_impl)

fact_keys_are_schema_qualified_test = unittest.make(_fact_keys_are_schema_qualified_impl)

registry_fetch_selection_remains_deterministic_test = unittest.make(_registry_fetch_selection_remains_deterministic_impl)

duplicate_hub_name_fails_test = _expect_failure("Duplicate crate.from_cargo repository name same_hub")

incompatible_git_overlay_fails_test = _expect_failure("incompatible additive BUILD content in hubs first_hub and second_hub")

conflicting_registry_credentials_fails_test = _expect_failure("Conflicting Cargo registry credentials")

def crate_metadata_tests():
    fact_keys_are_schema_qualified_test(name = "fact_keys_are_schema_qualified_test")
