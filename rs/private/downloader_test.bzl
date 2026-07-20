"""Tests for downloader cache-key isolation."""

load("@bazel_skylib//lib:unittest.bzl", "asserts", "unittest")
load(":downloader.bzl", "git_cargo_toml_fact_key", "git_cargo_toml_fact_keys", "new_downloader_state", "registry_cargo_toml_fact_key", "registry_metadata_key", "start_crate_registry_downloads", "start_github_downloads")

def _unexpected_download(*_args, **_kwargs):
    fail("A persisted Git lookup fact should prevent downloads")

def _git_fact_key_includes_manifest_view_impl(ctx):
    env = unittest.begin(ctx)
    source = "git+https://example.com/repo?rev=main#0123456789abcdef"

    workspace_view = git_cargo_toml_fact_key(source, "foo", "Cargo.toml", "crates/foo")
    direct_view = git_cargo_toml_fact_key(source, "foo", "crates/foo/Cargo.toml", "")
    other_prefix = git_cargo_toml_fact_key(source, "foo", "Cargo.toml", "other/foo")

    asserts.true(env, workspace_view != direct_view)
    asserts.true(env, workspace_view != other_prefix)
    asserts.equals(env, workspace_view, git_cargo_toml_fact_key(source, "foo", "Cargo.toml", "crates/foo"))
    return unittest.end(env)

git_fact_key_includes_manifest_view_test = unittest.make(_git_fact_key_includes_manifest_view_impl)

def _git_fact_keys_include_pre_discovery_lookup_impl(ctx):
    env = unittest.begin(ctx)
    source = "git+https://example.com/repo?rev=main#0123456789abcdef"

    lookup_key = git_cargo_toml_fact_key(source, "foo", "Cargo.toml", None)
    effective_key = git_cargo_toml_fact_key(source, "foo", "Cargo.toml", "crates/foo")

    asserts.equals(
        env,
        [effective_key, lookup_key],
        git_cargo_toml_fact_keys(source, "foo", "Cargo.toml", None, "crates/foo"),
    )
    asserts.equals(
        env,
        [effective_key],
        git_cargo_toml_fact_keys(source, "foo", "Cargo.toml", "crates/foo", "crates/foo"),
    )
    return unittest.end(env)

git_fact_keys_include_pre_discovery_lookup_test = unittest.make(_git_fact_keys_include_pre_discovery_lookup_impl)

def _git_pre_discovery_fact_skips_fetch_impl(ctx):
    env = unittest.begin(ctx)
    github_source = "git+https://github.com/example/repo?rev=main#0123456789abcdef"
    other_source = "git+https://gitlab.com/example/repo?rev=main#0123456789abcdef"
    serialized_fact = json.encode({
        "dependencies": [],
        "features": {},
        "is_proc_macro": False,
        "strip_prefix": "crates/foo",
    })
    facts = {
        git_cargo_toml_fact_key(github_source, "foo", "Cargo.toml", None): serialized_fact,
        git_cargo_toml_fact_key(other_source, "foo", "Cargo.toml", None): serialized_fact,
    }
    mctx = struct(
        download = _unexpected_download,
        facts = facts,
    )
    state = new_downloader_state()
    github_package = {
        "hub_name": "crates",
        "name": "foo",
        "source": github_source,
        "version": "1.0.0",
    }
    other_package = {
        "hub_name": "crates",
        "name": "foo",
        "source": other_source,
        "version": "1.0.0",
    }

    start_github_downloads(mctx, state, {}, [github_package])
    start_crate_registry_downloads(mctx, state, {}, [other_package], {}, False)

    asserts.equals(env, "crates/foo", github_package.get("strip_prefix"))
    asserts.equals(env, "crates/foo", other_package.get("strip_prefix"))
    asserts.equals(env, {}, state.in_flight_git_crate_fetches_by_url)
    asserts.equals(env, {}, state.pending_git_clones_by_source)
    return unittest.end(env)

git_pre_discovery_fact_skips_fetch_test = unittest.make(_git_pre_discovery_fact_skips_fetch_impl)

def _registry_keys_include_source_impl(ctx):
    env = unittest.begin(ctx)
    source_a = "sparse+https://registry-a.example/index/"
    source_b = "sparse+https://registry-b.example/index/"

    asserts.true(
        env,
        registry_cargo_toml_fact_key(source_a, "shared", "1.0.0") !=
        registry_cargo_toml_fact_key(source_b, "shared", "1.0.0"),
    )
    asserts.true(
        env,
        registry_metadata_key(source_a, "shared") != registry_metadata_key(source_b, "shared"),
    )
    return unittest.end(env)

registry_keys_include_source_test = unittest.make(_registry_keys_include_source_impl)

def downloader_tests():
    return unittest.suite(
        "downloader_tests",
        git_fact_key_includes_manifest_view_test,
        git_fact_keys_include_pre_discovery_lookup_test,
        git_pre_discovery_fact_skips_fetch_test,
        registry_keys_include_source_test,
    )
