load("@bazel_skylib//lib:unittest.bzl", "asserts", "unittest")
load(":cargo_workspace_graph.bzl", "cargo_platforms", "cargo_toml_dependencies", "locked_dependency_versions", "new_feature_resolutions", "resolve_cargo_workspace_members", "resolve_package_facts", "select_dependency_version", "split_lockfile_packages")
load(":resolver.bzl", "resolve")

def _select_dependency_version_uses_package_name_impl(ctx):
    env = unittest.begin(ctx)

    got = select_dependency_version(
        {
            "name": "alloc",
            "package": "rustc-std-workspace-alloc",
            "req": "1.0.0",
        },
        {
            "rustc-std-workspace-alloc": ["1.99.0"],
        },
    )

    asserts.equals(env, "1.99.0", got)
    return unittest.end(env)

def _select_dependency_version_uses_req_for_duplicate_versions_impl(ctx):
    env = unittest.begin(ctx)

    versions_by_name = locked_dependency_versions(
        {
            "dependencies": [
                "wasi 0.11.1+wasi-snapshot-preview1",
                "wasi 0.14.4+wasi-0.2.4",
            ],
        },
        {},
    )

    got_wasi = select_dependency_version(
        {
            "name": "wasi",
            "req": "0.11.0",
        },
        versions_by_name,
    )
    got_wasip2 = select_dependency_version(
        {
            "name": "wasip2",
            "package": "wasi",
            "req": "0.14.4",
        },
        versions_by_name,
    )

    asserts.equals(env, "0.11.1+wasi-snapshot-preview1", got_wasi)
    asserts.equals(env, "0.14.4+wasi-0.2.4", got_wasip2)
    return unittest.end(env)

select_dependency_version_uses_package_name_test = unittest.make(_select_dependency_version_uses_package_name_impl)
select_dependency_version_uses_req_for_duplicate_versions_test = unittest.make(_select_dependency_version_uses_req_for_duplicate_versions_impl)

def _cargo_toml_dependencies_normalizes_dependency_specs_impl(ctx):
    env = unittest.begin(ctx)

    got = cargo_toml_dependencies(
        {
            "package": {
                "name": "test",
            },
            "dependencies": {
                "alloc": {
                    "features": ["serde"],
                    "package": "rustc-std-workspace-alloc",
                    "path": "../rustc-std-workspace-alloc",
                    "version": "1.0.0",
                },
                "serde": "1",
            },
            "target": {
                "cfg(windows)": {
                    "dependencies": {
                        "windows-sys": {
                            "version": "1",
                        },
                    },
                },
            },
        },
    )

    asserts.equals(env, [
        {
            "default_features": True,
            "features": ["serde"],
            "name": "alloc",
            "optional": False,
            "package": "rustc-std-workspace-alloc",
            "req": "1.0.0",
        },
        {
            "name": "serde",
            "req": "1",
        },
        {
            "default_features": True,
            "features": [],
            "name": "windows-sys",
            "optional": False,
            "req": "1",
            "target": "cfg(windows)",
        },
    ], got)
    return unittest.end(env)

cargo_toml_dependencies_normalizes_dependency_specs_test = unittest.make(_cargo_toml_dependencies_normalizes_dependency_specs_impl)

def _cargo_toml_dependencies_handles_workspace_inheritance_impl(ctx):
    env = unittest.begin(ctx)

    got = cargo_toml_dependencies(
        {
            "package": {
                "name": "test",
            },
            "dependencies": {
                "serde": {
                    "features": ["derive"],
                    "workspace": True,
                },
            },
        },
        {
            "workspace": {
                "dependencies": {
                    "serde": {
                        "default-features": False,
                        "features": ["alloc"],
                        "version": "1.0.0",
                    },
                },
            },
        },
    )

    asserts.equals(env, [
        {
            "default_features": False,
            "features": ["alloc", "derive"],
            "name": "serde",
            "optional": False,
            "req": "1.0.0",
        },
    ], got)
    return unittest.end(env)

cargo_toml_dependencies_handles_workspace_inheritance_test = unittest.make(_cargo_toml_dependencies_handles_workspace_inheritance_impl)

def _split_lockfile_packages_finds_local_package_paths_impl(ctx):
    env = unittest.begin(ctx)

    got = split_lockfile_packages(
        hub_name = "hub",
        cargo_metadata = {
            "packages": [
                {
                    "dependencies": [
                        {
                            "name": "path-dep",
                            "path": "/repo/crates/path-dep",
                        },
                    ],
                    "manifest_path": "/repo/root/Cargo.toml",
                    "name": "root",
                    "version": "0.1.0",
                },
            ],
        },
        all_packages = [
            {
                "name": "root",
                "version": "0.1.0",
            },
            {
                "name": "path-dep",
                "version": "1.0.0",
            },
            {
                "name": "patched-crate",
                "version": "1.0.0",
            },
            {
                "name": "serde",
                "source": "sparse+https://index.crates.io/",
                "version": "1.0.0",
            },
        ],
        workspace_cargo_toml = {
            "patch": {
                "crates-io": {
                    "patched": {
                        "package": "patched-crate",
                        "path": "vendor/patched",
                    },
                },
            },
        },
        repo_root = "/repo",
    )

    asserts.equals(env, [
        {
            "name": "root",
            "version": "0.1.0",
        },
    ], got.workspace_members)
    asserts.equals(env, [
        {
            "local_path": "/repo/crates/path-dep",
            "name": "path-dep",
            "source": "path+hub/crates/path-dep",
            "version": "1.0.0",
        },
        {
            "local_path": "/repo/vendor/patched",
            "name": "patched-crate",
            "source": "path+hub/vendor/patched",
            "version": "1.0.0",
        },
        {
            "name": "serde",
            "source": "sparse+https://index.crates.io/",
            "version": "1.0.0",
        },
    ], got.packages)
    return unittest.end(env)

split_lockfile_packages_finds_local_package_paths_test = unittest.make(_split_lockfile_packages_finds_local_package_paths_impl)

def _resolve_package_facts_attaches_feature_resolutions_impl(ctx):
    env = unittest.begin(ctx)

    packages = [
        {
            "name": "serde",
            "version": "1.0.0",
        },
    ]
    got = resolve_package_facts(
        packages,
        {
            "serde-1.0.0": {
                "dependencies": [
                    {
                        "name": "serde_derive",
                        "optional": True,
                    },
                ],
                "features": {
                    "derive": ["dep:serde_derive"],
                },
            },
        },
    )

    asserts.equals(env, {"serde": ["1.0.0"]}, got.versions_by_name)
    asserts.true(env, "feature_resolutions" in packages[0])
    asserts.equals(env, ["serde-1.0.0"], got.feature_resolutions_by_fq_crate.keys())
    return unittest.end(env)

resolve_package_facts_attaches_feature_resolutions_test = unittest.make(_resolve_package_facts_attaches_feature_resolutions_impl)

def _resolve_handles_dependency_chains_deeper_than_previous_round_limit_impl(ctx):
    env = unittest.begin(ctx)

    triple = "x86_64-unknown-linux-gnu"
    triples = [triple]
    packages = []
    resolutions = []
    for index in range(60):
        name = "chain-%s" % index
        possible_deps = []
        if index:
            possible_deps.append({
                "bazel_target": "//:chain-%s" % (index - 1),
                "package_index": index - 1,
                "name": "chain-%s" % (index - 1),
                "platforms": 1,
            })

        possible_features = {"forward": []}
        if index:
            possible_features["forward"] = ["chain-%s/forward" % (index - 1)]

        resolution = new_feature_resolutions(index, possible_deps, possible_features)
        resolutions.append(resolution)
        packages.append({
            "feature_resolutions": resolution,
            "name": name,
            "version": "1.0.0",
        })

    resolutions[-1].feature_seeds.append((["forward"], 1))
    resolve(None, packages, cargo_platforms(triples), False)

    asserts.true(env, "forward" in resolutions[0].features_enabled[triple])
    asserts.equals(env, ["//:chain-0"], sorted(resolutions[1].deps[triple]))
    return unittest.end(env)

resolve_handles_dependency_chains_deeper_than_previous_round_limit_test = unittest.make(_resolve_handles_dependency_chains_deeper_than_previous_round_limit_impl)

def _platform_bits_impl(ctx):
    env = unittest.begin(ctx)
    triples = ["x86_64-vendor%s-linux-gnu" % i for i in range(513)]
    platforms = cargo_platforms(triples)
    last = platforms.bits[triples[-1]]
    asserts.equals(env, platforms.bits[triples[-2]] * 2, last)
    asserts.equals(env, last * 2 - 1, platforms.all_mask)
    return unittest.end(env)

platform_bits_test = unittest.make(_platform_bits_impl)

def _resolve_codec_dependency(triples, dependency, features, crate_features_select, crate_features = []):
    packages = [{"name": "codec", "version": "1"}, {"name": "consumer", "version": "1"}]
    resolved = resolve_package_facts(packages, {
        "codec-1": {},
        "consumer-1": {"dependencies": [dependency], "features": features},
    })
    resolve_cargo_workspace_members(
        None,
        cargo_metadata = {"packages": []},
        packages = packages,
        workspace_members = [],
        package_resolution = resolved,
        annotations = {"consumer": {"*": struct(crate_features = crate_features, crate_features_select = crate_features_select)}},
        platforms = cargo_platforms(triples),
        materialize_workspace_members = False,
    )
    return packages[0]["feature_resolutions"], packages[1]["feature_resolutions"]

def _late_optional_feature_impl(ctx):
    env = unittest.begin(ctx)
    linux = "x86_64-unknown-linux-gnu"
    macos = "aarch64-apple-darwin"
    windows = "x86_64-pc-windows-msvc"
    codec, consumer = _resolve_codec_dependency(
        [linux, macos, windows],
        dependency = {
            "name": "backend",
            "package": "codec",
            "optional": True,
            "default_features": False,
            "target": 'cfg(feature = "ready")',
        },
        features = {"forward": ["backend?/simd"], "later": ["next"], "next": ["ready"]},
        crate_features_select = {linux: ["ready"], macos: ["later"]},
        crate_features = ["forward", "dep:backend"],
    )
    for triple in [linux, macos]:
        asserts.equals(env, ["simd"], codec.features_enabled[triple])
        asserts.equals(env, ["//:codec-1"], consumer.deps[triple])
    asserts.equals(env, [], codec.features_enabled[windows])
    asserts.equals(env, [], consumer.deps[windows])
    asserts.equals(env, {"//:codec-1": "backend"}, consumer.aliases)
    return unittest.end(env)

late_optional_feature_test = unittest.make(_late_optional_feature_impl)

def _negated_feature_cfg_order_impl(ctx):
    env = unittest.begin(ctx)
    linux = "x86_64-unknown-linux-gnu"
    windows = "x86_64-pc-windows-msvc"
    codec, consumer = _resolve_codec_dependency(
        [linux, windows],
        dependency = {"name": "codec", "default_features": False, "target": 'cfg(not(feature = "off"))'},
        features = {"forward": ["codec/simd"], "disable": ["off"], "first": ["forward", "disable"], "last": ["disable", "forward"]},
        crate_features_select = {windows: ["last"], linux: ["first"]},
    )
    asserts.equals(env, [linux, windows], consumer.features_enabled.keys())
    asserts.equals(env, ["simd"], codec.features_enabled[linux])
    asserts.equals(env, [], codec.features_enabled[windows])
    return unittest.end(env)

negated_feature_cfg_order_test = unittest.make(_negated_feature_cfg_order_impl)

def _resolve_cargo_workspace_members_ignores_weak_features_for_unresolved_optional_deps_impl(ctx):
    env = unittest.begin(ctx)

    triple = "x86_64-unknown-linux-gnu"
    packages = [{
        "dependencies": [],
        "name": "flate2",
        "version": "1.0.0",
    }]
    package_resolution = resolve_package_facts(
        packages,
        {
            "flate2-1.0.0": {
                "dependencies": [{
                    "default_features": False,
                    "name": "zlib-rs",
                    "optional": True,
                    "req": "1",
                }],
                "features": {
                    "runtime_detection": ["zlib-rs?/std"],
                },
            },
        },
    )

    resolve_cargo_workspace_members(
        None,
        cargo_metadata = {
            "packages": [{
                "dependencies": [{
                    "features": ["runtime_detection"],
                    "name": "flate2",
                    "req": "1",
                    "source": "registry+https://github.com/rust-lang/crates.io-index",
                    "uses_default_features": False,
                }],
                "features": {},
                "manifest_path": "/workspace/Cargo.toml",
                "name": "consumer",
                "version": "0.1.0",
            }],
            "workspace_root": "/workspace",
        },
        packages = packages,
        workspace_members = [{
            "dependencies": ["flate2 1.0.0"],
            "name": "consumer",
            "version": "0.1.0",
        }],
        package_resolution = package_resolution,
        annotations = {},
        platforms = cargo_platforms([triple]),
        materialize_workspace_members = False,
    )

    flate2_resolution = package_resolution.feature_resolutions_by_fq_crate["flate2-1.0.0"]
    asserts.equals(env, ["runtime_detection"], sorted(flate2_resolution.features_enabled[triple]))
    asserts.equals(env, [], sorted(flate2_resolution.deps[triple]))
    return unittest.end(env)

resolve_cargo_workspace_members_ignores_weak_features_for_unresolved_optional_deps_test = unittest.make(_resolve_cargo_workspace_members_ignores_weak_features_for_unresolved_optional_deps_impl)

# Regression for https://github.com/hermeticbuild/rules_rs/issues/274.
def _target_build_dependencies_impl(ctx):
    env = unittest.begin(ctx)
    got = cargo_toml_dependencies(
        {"package": {"name": "consumer"}, "target": {"cfg(windows)": {
            "dependencies": {"runtime": "1"},
            "build-dependencies": {"generator": {"workspace": True, "optional": True, "features": ["extra"]}},
        }}},
        {"workspace": {"dependencies": {"generator": {"package": "actual-generator", "version": "2", "default-features": False, "features": ["base"]}}}},
    )
    asserts.equals(env, 2, len(got))
    asserts.equals(env, {"name": "runtime", "req": "1", "target": "cfg(windows)"}, got[0])
    asserts.equals(env, {
        "name": "generator",
        "package": "actual-generator",
        "req": "2",
        "target": "cfg(windows)",
        "kind": "build",
        "optional": True,
        "default_features": False,
        "features": ["base", "extra"],
    }, got[1])
    return unittest.end(env)

target_build_dependencies_test = unittest.make(_target_build_dependencies_impl)

def cargo_workspace_graph_tests():
    return unittest.suite(
        "cargo_workspace_graph_tests",
        target_build_dependencies_test,
        platform_bits_test,
        late_optional_feature_test,
        negated_feature_cfg_order_test,
        cargo_toml_dependencies_handles_workspace_inheritance_test,
        cargo_toml_dependencies_normalizes_dependency_specs_test,
        resolve_handles_dependency_chains_deeper_than_previous_round_limit_test,
        resolve_cargo_workspace_members_ignores_weak_features_for_unresolved_optional_deps_test,
        resolve_package_facts_attaches_feature_resolutions_test,
        select_dependency_version_uses_package_name_test,
        select_dependency_version_uses_req_for_duplicate_versions_test,
        split_lockfile_packages_finds_local_package_paths_test,
    )
