"""Compare the resolver's compilation contexts with Cargo's actual unit graph."""

load("@bazel_skylib//lib:unittest.bzl", "asserts", "unittest")
load("//rs/private:all_crate_deps.bzl", "all_crate_deps", "crate_aliases")
load("//rs/private:cargo_workspace_graph.bzl", "cargo_toml_fact", "resolve_cargo_workspace_members", "resolve_packages", "workspace_dep_data")
load("//rs/private:crate_configurations.bzl", "prepare_crate_configurations")
load("//rs/private:downloader.bzl", "download_metadata_for_git_crates", "git_crate_strip_prefix", "git_manifest_fact_key", "new_downloader_state", "start_crate_registry_downloads", "start_github_downloads")
load(":oracle.bzl", "CASES", "METADATA")

_HOST = "aarch64-apple-darwin"

def _oracle_impl(ctx):
    env = unittest.begin(ctx)
    case = CASES[ctx.attr.case]

    # Resolution annotates dependencies, so every test gets independent input.
    metadata = json.decode(json.encode(METADATA))
    package_resolution = resolve_packages([], {}, [case["target"]])
    result = resolve_cargo_workspace_members(
        None,
        cargo_metadata = metadata,
        packages = [],
        workspace_members = [dict(p, dependencies = [d["name"] + " 1.0.0" for d in p["dependencies"]]) for p in metadata["packages"]],
        versions_by_name = package_resolution.versions_by_name,
        feature_resolutions_by_fq_crate = package_resolution.feature_resolutions_by_fq_crate,
        annotations = {},
        platform_triples = [case["target"]],
        exec_platform_triples = [_HOST],
        materialize_workspace_members = True,
        root_packages = [case["package"]],
        include_dev = case["include_dev"],
    )
    by_id = {p["id"]: p["name"] + "-" + p["version"] for p in metadata["packages"]}
    expected = {}
    for unit in case["units"]:
        domain = "target" if unit["platform"] else "host"
        expected[(by_id[unit["id"]], domain)] = sorted(unit["features"])
    actual = {}
    for domain, records, triple in [
        ("target", result.feature_resolutions_by_fq_crate, case["target"]),
        ("host", result.exec_resolutions_by_cargo_target_triple[case["target"]].resolutions, _HOST),
    ]:
        for name, record in records.items():
            if triple in record.active:
                actual[(name, domain)] = sorted([f for f in record.features_enabled[triple] if not f.startswith("dep:")])
    asserts.equals(env, expected, actual, "%s on %s (dev=%s)" % (case["package"], case["target"], case["include_dev"]))
    root = case["package"] + "-1.0.0"
    asserts.equals(env, sorted([":" + fq for fq, domain in expected if fq != root and domain == "target"]), result.workspace_dep_labels_by_triple[case["target"]])
    asserts.equals(env, sorted([":" + fq for fq, domain in expected if fq != root and domain == "host"]), result.workspace_exec_dep_labels_by_cargo_target_triple[case["target"]][_HOST])
    if case["package"] == "consumer":
        asserts.equals(env, "renamed", result.feature_resolutions_by_fq_crate["consumer-1.0.0"].deps[case["target"]]["//:derive-package-1.0.0"])
        configurations = prepare_crate_configurations(
            result.feature_resolutions_by_fq_crate,
            result.exec_resolutions_by_cargo_target_triple,
            dep_label_prefix = "//:",
            exec_platform_triples = [_HOST],
            workspace_crates = result.feature_resolutions_by_fq_crate.keys(),
        )
        data = workspace_dep_data(
            cargo_metadata = metadata,
            dep_label_prefix = "//:",
            platform_triples = [case["target"]],
            platform_cfg_attrs = result.platform_cfg_attrs,
            cfg_match_cache = result.cfg_match_cache,
            repo_root = "/workspace",
            workspace_package = "",
            use_legacy_rules_rust_platforms = False,
            configurations_by_crate = configurations,
        )["consumer"]
        asserts.equals(env, ["//:derive-package-1.0.0", "//:helper-1.0.0"], all_crate_deps(data, hub_name = "oracle"))
        asserts.false(env, "//:dev-macro-1.0.0" in crate_aliases(data, hub_name = "oracle"))
        asserts.equals(env, "macro_test", crate_aliases(data, normal_dev = True, hub_name = "oracle")["//:dev-macro-1.0.0"])
    return unittest.end(env)

_oracle_test = unittest.make(_oracle_impl, attrs = {"case": attr.int()})

def _manifest_impl(ctx):
    env = unittest.begin(ctx)
    fact = cargo_toml_fact({"package": {"name": "derive-package"}, "lib": {"proc-macro": True, "name": "renamed_macro"}})
    asserts.true(env, fact["proc_macro"])
    asserts.equals(env, "renamed_macro", fact["crate_name"])
    ordinary = cargo_toml_fact({"package": {"name": "ordinary-library"}})
    asserts.false(env, ordinary["proc_macro"])
    asserts.equals(env, "ordinary_library", ordinary["crate_name"])
    return unittest.end(env)

_manifest_test = unittest.make(_manifest_impl)

def feature_context_tests():
    for index, case in enumerate(CASES):
        _oracle_test(name = "%s_%s_%s_test" % (case["package"], case["target"], "dev" if case["include_dev"] else "build"), case = index)
    _manifest_test(name = "manifest_test")

# No download/execute methods are supplied: a warm-facts path must not use them.
def _warm_git_facts_impl(ctx):
    env = unittest.begin(ctx)
    for remote in ["https://github.com/example/workspace", "https://example.invalid/workspace"]:
        package = {"source": "git+" + remote + "#" + "a" * 40, "name": "member", "version": "1.0.0", "hub_name": "oracle"}
        facts = {git_manifest_fact_key(package["source"], package["name"]): json.encode({"strip_prefix": "crates/member", "proc_macro": True, "crate_name": "renamed_macro"})}
        state = new_downloader_state()
        mctx = struct(facts = facts)
        start_github_downloads(mctx, state, {}, [package])
        start_crate_registry_downloads(mctx, state, {}, [package], {}, False)
        download_metadata_for_git_crates(mctx, state, {})
        asserts.equals(env, "crates/member", git_crate_strip_prefix(package, facts))
        asserts.equals(env, "", git_crate_strip_prefix(dict(package, strip_prefix = ""), facts))
    return unittest.end(env)

warm_git_facts_test = unittest.make(_warm_git_facts_impl)
