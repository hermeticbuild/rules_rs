"""Compare the resolver's compilation contexts with Cargo's actual unit graph."""

load("@bazel_skylib//lib:unittest.bzl", "asserts", "unittest")
load("//rs/private:cargo_workspace_graph.bzl", "cargo_toml_fact", "resolve_cargo_workspace_members", "resolve_packages")
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
    if case["package"] == "consumer":
        asserts.equals(env, "renamed", result.feature_resolutions_by_fq_crate["consumer-1.0.0"].deps[case["target"]]["//:derive-package-1.0.0"])
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
