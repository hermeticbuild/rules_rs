load("@bazel_skylib//lib:unittest.bzl", "asserts", "unittest")
load(":cargo_workspace_graph.bzl", "cargo_toml_dependencies", "compute_package_fq_deps", "resolve_package_facts", "select_package_fq_dep", "split_lockfile_packages")

def _select_package_fq_dep_uses_package_name_impl(ctx):
    env = unittest.begin(ctx)

    got = select_package_fq_dep(
        {
            "name": "alloc",
            "package": "rustc-std-workspace-alloc",
            "req": "1.0.0",
        },
        {
            "rustc-std-workspace-alloc": ["rustc-std-workspace-alloc-1.99.0"],
        },
    )

    asserts.equals(env, "rustc-std-workspace-alloc-1.99.0", got)
    return unittest.end(env)

def _select_package_fq_dep_uses_req_for_duplicate_versions_impl(ctx):
    env = unittest.begin(ctx)

    fq_deps = compute_package_fq_deps(
        {
            "dependencies": [
                "wasi 0.11.1+wasi-snapshot-preview1",
                "wasi 0.14.4+wasi-0.2.4",
            ],
        },
        {},
    )

    got_wasi = select_package_fq_dep(
        {
            "name": "wasi",
            "req": "0.11.0",
        },
        fq_deps,
    )
    got_wasip2 = select_package_fq_dep(
        {
            "name": "wasip2",
            "package": "wasi",
            "req": "0.14.4",
        },
        fq_deps,
    )

    asserts.equals(env, "wasi-0.11.1+wasi-snapshot-preview1", got_wasi)
    asserts.equals(env, "wasi-0.14.4+wasi-0.2.4", got_wasip2)
    return unittest.end(env)

select_package_fq_dep_uses_package_name_test = unittest.make(_select_package_fq_dep_uses_package_name_impl)
select_package_fq_dep_uses_req_for_duplicate_versions_test = unittest.make(_select_package_fq_dep_uses_req_for_duplicate_versions_impl)

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
        ["x86_64-unknown-linux-gnu"],
        exec_platform_triples = ["aarch64-apple-darwin"],
    )

    asserts.equals(env, {"serde": ["1.0.0"]}, got.versions_by_name)
    asserts.true(env, "feature_resolutions" in packages[0])
    asserts.true(env, "exec_feature_resolutions" in packages[0])
    asserts.equals(env, ["serde-1.0.0"], got.feature_resolutions_by_fq_crate.keys())
    asserts.equals(env, ["serde-1.0.0"], got.exec_feature_resolutions_by_fq_crate.keys())
    asserts.equals(env, ["x86_64-unknown-linux-gnu"], got.feature_resolutions_by_fq_crate["serde-1.0.0"].active.keys())
    asserts.equals(env, ["aarch64-apple-darwin"], got.exec_feature_resolutions_by_fq_crate["serde-1.0.0"].active.keys())
    return unittest.end(env)

resolve_package_facts_attaches_feature_resolutions_test = unittest.make(_resolve_package_facts_attaches_feature_resolutions_impl)

def cargo_workspace_graph_tests():
    return unittest.suite(
        "cargo_workspace_graph_tests",
        cargo_toml_dependencies_handles_workspace_inheritance_test,
        cargo_toml_dependencies_normalizes_dependency_specs_test,
        resolve_package_facts_attaches_feature_resolutions_test,
        select_package_fq_dep_uses_package_name_test,
        select_package_fq_dep_uses_req_for_duplicate_versions_test,
        split_lockfile_packages_finds_local_package_paths_test,
    )
