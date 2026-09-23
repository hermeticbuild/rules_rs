load("@bazel_skylib//lib:unittest.bzl", "asserts", "unittest")
load(":cargo_workspace_graph.bzl", "cargo_toml_dependencies", "compute_package_dep_versions", "new_feature_resolutions", "resolve_cargo_workspace_members", "resolve_packages", "select_package_dep_version", "split_lockfile_packages")
load(":resolver.bzl", "resolve")

def _select_package_dep_version_impl(ctx):
    env = unittest.begin(ctx)

    versions = compute_package_dep_versions(
        {
            "dependencies": [
                "wasi 0.11.1+wasi-snapshot-preview1",
                "wasi 0.14.4+wasi-0.2.4",
            ],
        },
        {},
    )["wasi"]

    asserts.equals(env, "0.11.1+wasi-snapshot-preview1", select_package_dep_version({"req": "0.11.0"}, versions))
    asserts.equals(env, "0.14.4+wasi-0.2.4", select_package_dep_version({"req": "0.14.4"}, versions))
    asserts.equals(env, "1.99.0", select_package_dep_version({"req": "2"}, ["1.99.0"]))
    return unittest.end(env)

select_package_dep_version_test = unittest.make(_select_package_dep_version_impl)

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

def _resolve_packages_attaches_feature_resolutions_impl(ctx):
    env = unittest.begin(ctx)

    packages = [
        {
            "name": "serde",
            "version": "1.0.0",
        },
    ]
    got = resolve_packages(
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
    )

    asserts.equals(env, {"serde": ["1.0.0"]}, got.versions_by_name)
    asserts.true(env, "feature_resolutions" in packages[0])
    asserts.equals(env, ["serde-1.0.0"], got.feature_resolutions_by_fq_crate.keys())
    return unittest.end(env)

resolve_packages_attaches_feature_resolutions_test = unittest.make(_resolve_packages_attaches_feature_resolutions_impl)

def _resolve_handles_dependency_chains_deeper_than_previous_round_limit_impl(ctx):
    env = unittest.begin(ctx)

    platform_triple = "x86_64-unknown-linux-gnu"
    triples = [platform_triple]
    packages = []
    resolutions = []
    for index in range(60):
        name = "chain-%s" % index
        possible_deps = []
        if index:
            possible_deps.append({
                "bazel_target": "//:chain-%s" % (index - 1),
                "name": "chain-%s" % (index - 1),
                "package_index": index - 1,
                "target": set(triples),
            })

        possible_features = {"forward": []}
        if index:
            possible_features["forward"] = ["chain-%s/forward" % (index - 1)]

        resolution = new_feature_resolutions(index, possible_deps, possible_features, triples)
        resolutions.append(resolution)
        packages.append({
            "feature_resolutions": resolution,
            "name": name,
            "version": "1.0.0",
        })

    resolutions[-1].active.add(platform_triple)
    resolutions[-1].features_enabled[platform_triple].add("forward")
    resolve(None, packages, {}, False)

    asserts.true(env, "forward" in resolutions[0].features_enabled[platform_triple])
    asserts.equals(env, ["//:chain-0"], sorted(resolutions[1].deps[platform_triple]))
    return unittest.end(env)

resolve_handles_dependency_chains_deeper_than_previous_round_limit_test = unittest.make(_resolve_handles_dependency_chains_deeper_than_previous_round_limit_impl)

def _resolve_test_workspace(facts_by_name, root_dependencies, cargo_target_triples, exec_platform_triples, annotations = {}):
    packages = [{
        "dependencies": sorted(set([
            (dep.get("package") or dep["name"]) + " 1.0.0"
            for dep in facts.get("dependencies", [])
            if (dep.get("package") or dep["name"]) in facts_by_name
        ])),
        "name": name,
        "version": "1.0.0",
    } for name, facts in facts_by_name.items()]
    package_resolution = resolve_packages(
        packages,
        {name + "-1.0.0": facts for name, facts in facts_by_name.items()},
        cargo_target_triples,
    )

    return resolve_cargo_workspace_members(
        None,
        cargo_metadata = {
            "packages": [{
                "dependencies": [dict({
                    "req": "1",
                    "source": "registry+https://github.com/rust-lang/crates.io-index",
                    "uses_default_features": False,
                }, **dep) for dep in root_dependencies],
                "features": {},
                "manifest_path": "/workspace/Cargo.toml",
                "name": "consumer",
                "version": "0.1.0",
            }],
            "workspace_root": "/workspace",
        },
        packages = packages,
        workspace_members = [{
            "dependencies": sorted(set([dep["name"] + " 1.0.0" for dep in root_dependencies])),
            "name": "consumer",
            "version": "0.1.0",
        }],
        versions_by_name = package_resolution.versions_by_name,
        feature_resolutions_by_fq_crate = package_resolution.feature_resolutions_by_fq_crate,
        annotations = annotations,
        platform_triples = cargo_target_triples,
        exec_platform_triples = exec_platform_triples,
        materialize_workspace_members = False,
    )

def _resolve_cargo_workspace_members_separates_target_and_exec_features_impl(ctx):
    env = unittest.begin(ctx)
    linux = "x86_64-unknown-linux-gnu"
    macos = "aarch64-apple-darwin"

    got = _resolve_test_workspace(
        {
            "shared": {
                "dependencies": [{
                    "default_features": False,
                    "name": name,
                    "optional": True,
                } for name in ["target-only", "exec-only"]],
                "features": {
                    "target": ["dep:target-only"],
                    "exec": ["dep:exec-only"],
                },
            },
            "target-only": {},
            "exec-only": {},
        },
        [
            {"features": ["target"], "name": "shared"},
            {"features": ["exec"], "kind": "build", "name": "shared"},
        ],
        [linux],
        [linux, macos],
    )

    target = got.feature_resolutions_by_fq_crate["shared-1.0.0"]
    execution = got.exec_resolutions_by_cargo_target_triple[linux].resolutions["shared-1.0.0"]
    asserts.equals(env, ["dep:target-only", "target"], sorted(target.features_enabled[linux]))
    asserts.equals(env, ["//:target-only-1.0.0"], sorted(target.deps[linux]))
    asserts.equals(env, [], sorted(got.feature_resolutions_by_fq_crate["exec-only-1.0.0"].active))
    for platform_triple in [linux, macos]:
        asserts.equals(env, ["dep:exec-only", "exec"], sorted(execution.features_enabled[platform_triple]))
        asserts.equals(env, ["//:exec-only-1.0.0"], sorted(execution.deps[platform_triple]))
    asserts.equals(env, [], sorted(got.exec_resolutions_by_cargo_target_triple[linux].resolutions["target-only-1.0.0"].active))
    return unittest.end(env)

resolve_cargo_workspace_members_separates_target_and_exec_features_test = unittest.make(_resolve_cargo_workspace_members_separates_target_and_exec_features_impl)

def _resolve_cargo_workspace_members_preserves_proc_macro_host_dependencies_impl(ctx):
    env = unittest.begin(ctx)
    linux = "x86_64-unknown-linux-gnu"
    macos = "aarch64-apple-darwin"

    # Registry facts do not identify proc macros. A Linux-only normal
    # dependency can therefore still need its dependencies on macOS.
    got = _resolve_test_workspace(
        {
            "macro": {
                "dependencies": [
                    {"default_features": False, "name": "macro-support"},
                    {"default_features": False, "name": "macro-helper", "optional": True},
                ],
                "features": {"helper": ["dep:macro-helper"]},
            },
            "macro-support": {
                "dependencies": [{
                    "default_features": False,
                    "kind": "build",
                    "name": "darwin-build",
                    "target": 'cfg(target_os = "macos")',
                }],
                "features": {"exec-only": []},
            },
            "macro-helper": {},
            "darwin-build": {},
            "builder": {
                "dependencies": [{
                    "default_features": False,
                    "features": ["exec-only"],
                    "name": "macro-support",
                }],
            },
        },
        [
            {"name": "macro", "target": 'cfg(target_os = "linux")'},
            {"kind": "build", "name": "builder"},
        ],
        [linux, macos],
        [linux, macos],
        annotations = {"macro": {"*": struct(
            crate_features = [],
            crate_features_select = {macos: ["helper"]},
        )}},
    )

    macro = got.feature_resolutions_by_fq_crate["macro-1.0.0"]
    support = got.feature_resolutions_by_fq_crate["macro-support-1.0.0"]
    exec_support = got.exec_resolutions_by_cargo_target_triple[linux].resolutions["macro-support-1.0.0"]
    asserts.equals(env, ["//:macro-support-1.0.0"], sorted(macro.deps[linux]))
    asserts.equals(env, ["//:macro-helper-1.0.0", "//:macro-support-1.0.0"], sorted(macro.deps[macos]))
    asserts.equals(env, ["dep:macro-helper", "helper"], sorted(macro.features_enabled[macos]))
    asserts.false(env, linux in got.exec_resolutions_by_cargo_target_triple[linux].build_deps["macro-support-1.0.0"])
    asserts.equals(env, ["//:darwin-build-1.0.0"], sorted(got.exec_resolutions_by_cargo_target_triple[linux].build_deps["macro-support-1.0.0"][macos]))
    asserts.equals(env, [macos], sorted(got.exec_resolutions_by_cargo_target_triple[linux].resolutions["darwin-build-1.0.0"].active))

    # Expanding normal dependencies to other platforms must not process the
    # normal dependencies of a package reached only through a build dependency.
    asserts.equals(env, [], sorted(got.feature_resolutions_by_fq_crate["builder-1.0.0"].active))
    for platform_triple in [linux, macos]:
        asserts.equals(env, [], sorted(support.features_enabled[platform_triple]))
        asserts.equals(env, ["exec-only"], sorted(exec_support.features_enabled[platform_triple]))
    return unittest.end(env)

resolve_cargo_workspace_members_preserves_proc_macro_host_dependencies_test = unittest.make(_resolve_cargo_workspace_members_preserves_proc_macro_host_dependencies_impl)

def _resolve_cargo_workspace_members_keeps_target_optional_build_deps_on_exec_platform_impl(ctx):
    env = unittest.begin(ctx)
    linux = "x86_64-unknown-linux-gnu"
    macos = "aarch64-apple-darwin"

    got = _resolve_test_workspace(
        {
            "libdbus-sys": {
                "dependencies": [{
                    "default_features": False,
                    "kind": "build",
                    "name": name,
                    "optional": True,
                } for name in ["cc", "unused"]],
                "features": {"vendored": ["cc"]},
            },
            "cc": {
                "dependencies": [{
                    "default_features": False,
                    "name": "darwin-helper",
                    "target": 'cfg(target_os = "macos")',
                }],
            },
            "darwin-helper": {},
            "unused": {},
        },
        [{"name": "libdbus-sys"}],
        [linux, macos],
        [linux, macos],
        annotations = {"libdbus-sys": {"*": struct(
            crate_features = [],
            crate_features_select = {linux: ["vendored"]},
        )}},
    )

    libdbus = got.feature_resolutions_by_fq_crate["libdbus-sys-1.0.0"]
    cc = got.exec_resolutions_by_cargo_target_triple[linux].resolutions["cc-1.0.0"]
    asserts.equals(env, ["cc", "vendored"], sorted(libdbus.features_enabled[linux]))
    asserts.equals(env, [], sorted(libdbus.features_enabled[macos]))
    for platform_triple in [linux, macos]:
        asserts.equals(env, ["//:cc-1.0.0"], sorted(got.exec_resolutions_by_cargo_target_triple[linux].build_deps["libdbus-sys-1.0.0"][platform_triple]))
        asserts.true(env, platform_triple in cc.active)
        asserts.equals(env, [], sorted(libdbus.build_deps[platform_triple]))
    asserts.equals(env, {}, got.exec_resolutions_by_cargo_target_triple[macos].build_deps)
    asserts.equals(env, [], sorted(got.exec_resolutions_by_cargo_target_triple[macos].resolutions["cc-1.0.0"].active))
    asserts.equals(env, [], sorted(cc.deps[linux]))
    asserts.equals(env, ["//:darwin-helper-1.0.0"], sorted(cc.deps[macos]))
    asserts.equals(env, [], sorted(got.feature_resolutions_by_fq_crate["cc-1.0.0"].active))
    asserts.equals(env, [], sorted(got.exec_resolutions_by_cargo_target_triple[linux].resolutions["unused-1.0.0"].active))
    return unittest.end(env)

resolve_cargo_workspace_members_keeps_target_optional_build_deps_on_exec_platform_test = unittest.make(_resolve_cargo_workspace_members_keeps_target_optional_build_deps_on_exec_platform_impl)

def _resolve_cargo_workspace_members_forwards_features_to_exec_only_build_deps_impl(ctx):
    env = unittest.begin(ctx)
    linux = "x86_64-unknown-linux-gnu"
    macos = "aarch64-apple-darwin"

    got = _resolve_test_workspace(
        {
            "builder": {
                "dependencies": [{
                    "default_features": False,
                    "kind": "build",
                    "name": "shared",
                    "optional": True,
                    "target": 'cfg(target_os = "macos")',
                }],
                "features": {"forward": ["shared/exec"]},
            },
            "shared": {"features": {"exec": []}},
        },
        [{"features": ["forward"], "name": "builder"}],
        [linux],
        [linux, macos],
    )

    shared = got.exec_resolutions_by_cargo_target_triple[linux].resolutions["shared-1.0.0"]
    asserts.false(env, linux in got.exec_resolutions_by_cargo_target_triple[linux].build_deps["builder-1.0.0"])
    asserts.equals(env, ["//:shared-1.0.0"], sorted(got.exec_resolutions_by_cargo_target_triple[linux].build_deps["builder-1.0.0"][macos]))
    asserts.equals(env, [macos], sorted(shared.active))
    asserts.equals(env, ["exec"], sorted(shared.features_enabled[macos]))
    asserts.equals(env, [], sorted(got.feature_resolutions_by_fq_crate["shared-1.0.0"].active))
    return unittest.end(env)

resolve_cargo_workspace_members_forwards_features_to_exec_only_build_deps_test = unittest.make(_resolve_cargo_workspace_members_forwards_features_to_exec_only_build_deps_impl)

def _resolve_cargo_workspace_members_adds_requested_binary_target_roots_impl(ctx):
    env = unittest.begin(ctx)
    windows = "x86_64-pc-windows-gnullvm"
    linux = "x86_64-unknown-linux-gnu"

    got = _resolve_test_workspace(
        {
            "bin-helper": {
                "dependencies": [
                    {"default_features": False, "name": "default-dep", "optional": True},
                    {"default_features": False, "features": ["exec-dep"], "kind": "build", "name": "build-support"},
                ],
                "features": {
                    "annotated": [],
                    "build-mode": [],
                    "default": ["dep:default-dep"],
                },
            },
            "default-dep": {},
            "build-support": {"features": {"exec-dep": []}},
        },
        [{"features": ["build-mode"], "kind": "build", "name": "bin-helper"}],
        [windows],
        [linux],
        annotations = {"bin-helper": {"*": struct(
            crate_features = ["annotated"],
            crate_features_select = {},
            gen_binaries = ["bin-helper"],
        )}},
    )

    target = got.feature_resolutions_by_fq_crate["bin-helper-1.0.0"]
    execution = got.exec_resolutions_by_cargo_target_triple[windows].resolutions["bin-helper-1.0.0"]
    asserts.equals(env, [windows], sorted(target.active))
    asserts.equals(env, ["annotated", "default", "dep:default-dep"], sorted(target.features_enabled[windows]))
    asserts.equals(env, ["//:default-dep-1.0.0"], sorted(target.deps[windows]))
    asserts.equals(env, ["//:build-support-1.0.0"], sorted(got.exec_resolutions_by_cargo_target_triple[windows].build_deps["bin-helper-1.0.0"][linux]))
    asserts.equals(env, ["annotated", "build-mode"], sorted(execution.features_enabled[linux]))
    asserts.equals(env, [], sorted(execution.deps[linux]))
    asserts.equals(env, [], sorted(got.feature_resolutions_by_fq_crate["build-support-1.0.0"].active))
    asserts.equals(env, [], sorted(got.exec_resolutions_by_cargo_target_triple[windows].resolutions["default-dep-1.0.0"].active))
    asserts.equals(env, ["exec-dep"], sorted(got.exec_resolutions_by_cargo_target_triple[windows].resolutions["build-support-1.0.0"].features_enabled[linux]))
    return unittest.end(env)

resolve_cargo_workspace_members_adds_requested_binary_target_roots_test = unittest.make(_resolve_cargo_workspace_members_adds_requested_binary_target_roots_impl)

def _resolve_cargo_workspace_members_preserves_requested_binary_target_features_impl(ctx):
    env = unittest.begin(ctx)
    windows = "x86_64-pc-windows-gnullvm"
    linux = "x86_64-unknown-linux-gnu"

    got = _resolve_test_workspace(
        {
            "middle": {
                "dependencies": [{"default_features": False, "features": ["requested"], "name": "bin-helper"}],
            },
            "bin-helper": {
                "dependencies": [{"default_features": False, "name": "default-dep", "optional": True}],
                "features": {
                    "build-mode": [],
                    "default": ["dep:default-dep"],
                    "requested": [],
                },
            },
            "default-dep": {},
        },
        [
            {"name": "middle"},
            {"features": ["build-mode"], "kind": "build", "name": "bin-helper"},
        ],
        [windows],
        [linux],
        annotations = {"bin-helper": {"*": struct(
            crate_features = [],
            crate_features_select = {},
            gen_binaries = ["bin-helper"],
        )}},
    )

    target = got.feature_resolutions_by_fq_crate["bin-helper-1.0.0"]
    execution = got.exec_resolutions_by_cargo_target_triple[windows].resolutions["bin-helper-1.0.0"]
    asserts.equals(env, ["requested"], sorted(target.features_enabled[windows]))
    asserts.equals(env, [], sorted(target.deps[windows]))
    asserts.equals(env, ["build-mode"], sorted(execution.features_enabled[linux]))
    asserts.equals(env, [], sorted(got.feature_resolutions_by_fq_crate["default-dep-1.0.0"].active))
    return unittest.end(env)

resolve_cargo_workspace_members_preserves_requested_binary_target_features_test = unittest.make(_resolve_cargo_workspace_members_preserves_requested_binary_target_features_impl)

def _resolve_cargo_workspace_members_ignores_weak_features_for_unresolved_optional_deps_impl(ctx):
    env = unittest.begin(ctx)
    linux = "x86_64-unknown-linux-gnu"
    macos = "aarch64-apple-darwin"

    got = _resolve_test_workspace(
        {
            "flate2": {
                "dependencies": [{
                    "default_features": False,
                    "kind": kind,
                    "name": "zlib-rs",
                    "optional": True,
                    "req": "1",
                } for kind in ["normal", "build"]],
                "features": {"runtime_detection": ["zlib-rs?/std"]},
            },
        },
        [{
            "features": ["runtime_detection"],
            "kind": kind,
            "name": "flate2",
        } for kind in ["normal", "build"]],
        [linux],
        [macos],
    )

    target = got.feature_resolutions_by_fq_crate["flate2-1.0.0"]
    execution = got.exec_resolutions_by_cargo_target_triple[linux].resolutions["flate2-1.0.0"]
    for resolution, platform_triple in [(target, linux), (execution, macos)]:
        asserts.equals(env, ["runtime_detection"], sorted(resolution.features_enabled[platform_triple]))
        asserts.equals(env, [], sorted(resolution.deps[platform_triple]))
        asserts.equals(env, [], sorted(resolution.build_deps[platform_triple]))
    return unittest.end(env)

resolve_cargo_workspace_members_ignores_weak_features_for_unresolved_optional_deps_test = unittest.make(_resolve_cargo_workspace_members_ignores_weak_features_for_unresolved_optional_deps_impl)

def _resolve_cargo_workspace_members_isolates_forwarded_build_features_impl(ctx):
    env = unittest.begin(ctx)
    linux = "x86_64-unknown-linux-gnu"
    macos = "aarch64-apple-darwin"
    got = _resolve_test_workspace(
        {
            "builder": {
                "dependencies": [{
                    "default_features": False,
                    "kind": "build",
                    "name": "selected",
                    "package": "helper",
                    "optional": True,
                }],
                "features": {
                    "linux": ["selected/linux"],
                    "macos": ["selected/macos"],
                },
            },
            "helper": {
                "dependencies": [{
                    "default_features": False,
                    "name": name,
                    "optional": True,
                } for name in ["linux-leaf", "macos-leaf"]],
                "features": {
                    "linux": ["dep:linux-leaf"],
                    "macos": ["dep:macos-leaf"],
                },
            },
            "linux-leaf": {},
            "macos-leaf": {},
        },
        [{"name": "builder"}],
        [linux, macos],
        [linux, macos],
        annotations = {"builder": {"*": struct(
            crate_features = [],
            crate_features_select = {linux: ["linux"], macos: ["macos"]},
        )}},
    )

    for cargo_target_triple, feature in [(linux, "linux"), (macos, "macos")]:
        helper = got.exec_resolutions_by_cargo_target_triple[cargo_target_triple].resolutions["helper-1.0.0"]
        for exec_platform_triple in [linux, macos]:
            asserts.equals(env, ["dep:" + feature + "-leaf", feature], sorted(helper.features_enabled[exec_platform_triple]))
            asserts.equals(env, ["//:" + feature + "-leaf-1.0.0"], sorted(helper.deps[exec_platform_triple]))
        asserts.equals(env, {
            platform_triple: {"//:helper-1.0.0": "selected"}
            for platform_triple in [linux, macos]
        }, got.exec_resolutions_by_cargo_target_triple[cargo_target_triple].build_deps["builder-1.0.0"])
    return unittest.end(env)

def _resolve_cargo_workspace_members_isolates_weak_build_features_impl(ctx):
    env = unittest.begin(ctx)
    linux = "x86_64-unknown-linux-gnu"
    macos = "aarch64-apple-darwin"
    windows = "x86_64-pc-windows-gnullvm"
    got = _resolve_test_workspace(
        {
            "builder": {
                "dependencies": [{
                    "default_features": False,
                    "kind": "build",
                    "name": "helper",
                    "optional": True,
                }],
                "features": {
                    "enable": ["forward"],
                    "forward": ["helper/base"],
                    "weak": ["helper?/extra"],
                },
            },
            "helper": {"features": {"base": [], "extra": []}},
        },
        [{"name": "builder"}],
        [linux, macos, windows],
        [macos],
        annotations = {"builder": {"*": struct(
            crate_features = [],
            crate_features_select = {
                linux: ["enable", "weak"],
                macos: ["enable"],
                windows: ["weak"],
            },
        )}},
    )

    linux_helper = got.exec_resolutions_by_cargo_target_triple[linux].resolutions["helper-1.0.0"]
    macos_helper = got.exec_resolutions_by_cargo_target_triple[macos].resolutions["helper-1.0.0"]
    windows_helper = got.exec_resolutions_by_cargo_target_triple[windows].resolutions["helper-1.0.0"]
    asserts.equals(env, ["base", "extra"], sorted(linux_helper.features_enabled[macos]))
    asserts.equals(env, ["base"], sorted(macos_helper.features_enabled[macos]))
    asserts.equals(env, [macos], sorted(macos_helper.active))
    asserts.equals(env, [], sorted(windows_helper.active))
    asserts.equals(env, {}, got.exec_resolutions_by_cargo_target_triple[windows].build_deps)
    return unittest.end(env)

def _resolve_cargo_workspace_members_groups_seeds_preserving_owners_impl(ctx):
    env = unittest.begin(ctx)
    linux = "x86_64-unknown-linux-gnu"
    macos = "aarch64-apple-darwin"
    got = _resolve_test_workspace(
        {
            "owner-a": {
                "dependencies": [{"default_features": False, "kind": "build", "name": "selected-a", "package": "shared", "optional": True}],
                "features": {"enable": ["selected-a/annotated"]},
            },
            "owner-b": {
                "dependencies": [{"default_features": False, "kind": "build", "name": "selected-b", "package": "shared", "optional": True}],
                "features": {"enable": ["dep:selected-b"]},
            },
            "shared": {"features": {"annotated": []}},
        },
        [{"name": "owner-a"}, {"name": "owner-b"}],
        [linux, macos],
        [macos],
        annotations = {
            "owner-a": {"*": struct(crate_features = [], crate_features_select = {linux: ["enable"]})},
            "owner-b": {"*": struct(crate_features = [], crate_features_select = {macos: ["enable"]})},
            "shared": {"*": struct(crate_features = ["annotated"], crate_features_select = {})},
        },
    )

    asserts.equals(env, {"owner-a-1.0.0": {macos: {"//:shared-1.0.0": "selected_a"}}}, got.exec_resolutions_by_cargo_target_triple[linux].build_deps)
    asserts.equals(env, {"owner-b-1.0.0": {macos: {"//:shared-1.0.0": "selected_b"}}}, got.exec_resolutions_by_cargo_target_triple[macos].build_deps)
    asserts.equals(env, ["annotated"], sorted(got.exec_resolutions_by_cargo_target_triple[linux].resolutions["shared-1.0.0"].features_enabled[macos]))

    # Both target triples must reference the same resolved dictionary, not
    # independently computed dictionaries with equal contents.
    got.exec_resolutions_by_cargo_target_triple[linux].resolutions["grouping_test"] = True
    asserts.equals(env, True, got.exec_resolutions_by_cargo_target_triple[macos].resolutions.get("grouping_test"))
    return unittest.end(env)

def _resolve_cargo_workspace_members_preserves_no_exec_resolution_impl(ctx):
    env = unittest.begin(ctx)
    linux = "x86_64-unknown-linux-gnu"
    got = _resolve_test_workspace(
        {
            "builder": {
                "dependencies": [{"default_features": False, "kind": "build", "name": "helper"}],
                "features": {"forward": ["helper/extra"]},
            },
            "helper": {"features": {"extra": []}},
        },
        [{"features": ["forward"], "name": "builder"}],
        [linux],
        [],
    )

    builder = got.feature_resolutions_by_fq_crate["builder-1.0.0"]
    helper = got.feature_resolutions_by_fq_crate["helper-1.0.0"]
    asserts.equals(env, ["//:helper-1.0.0"], sorted(builder.build_deps[linux]))
    asserts.equals(env, ["extra"], sorted(helper.features_enabled[linux]))
    asserts.equals(env, {}, got.exec_resolutions_by_cargo_target_triple)
    return unittest.end(env)

def _optional_dependency_aliases_follow_enabled_features_impl(ctx):
    env = unittest.begin(ctx)
    linux = "x86_64-unknown-linux-gnu"
    macos = "aarch64-apple-darwin"
    for selected in ["first-name", "second-name"]:
        got = _resolve_test_workspace(
            {
                "owner": {
                    "dependencies": [{
                        "default_features": False,
                        "kind": kind,
                        "name": name,
                        "optional": True,
                        "package": "helper",
                    } for kind in ["normal", "build"] for name in ["first-name", "second-name"]],
                    "features": {"selected": ["dep:" + selected]},
                },
                "helper": {},
            },
            [{"kind": kind, "name": "owner", "features": ["selected"]} for kind in ["normal", "build"]],
            [linux, macos],
            [macos],
        )

        expected = {"//:helper-1.0.0": selected.replace("-", "_")}
        owner = got.feature_resolutions_by_fq_crate["owner-1.0.0"]
        for platform_triple in [linux, macos]:
            asserts.equals(env, expected, owner.deps[platform_triple])
            asserts.equals(env, {macos: expected}, got.exec_resolutions_by_cargo_target_triple[platform_triple].build_deps["owner-1.0.0"])
            execution = got.exec_resolutions_by_cargo_target_triple[platform_triple].resolutions["owner-1.0.0"]
            for deps in [execution.deps, execution.build_deps]:
                asserts.equals(env, {macos: expected}, deps)
    return unittest.end(env)

def _inactive_crates_remain_unresolved_impl(ctx):
    env = unittest.begin(ctx)
    linux = "x86_64-unknown-linux-gnu"
    macos = "aarch64-apple-darwin"
    got = _resolve_test_workspace(
        {
            "inactive": {
                "dependencies": [
                    {"name": "normal-helper"},
                    {"kind": "build", "name": "build-helper"},
                    {"default_features": False, "name": "unused", "optional": True},
                    {"default_features": False, "kind": "build", "name": "unused-build", "optional": True},
                ],
                "features": {"default": ["dep:unused", "dep:unused-build"]},
            },
            "normal-helper": {
                "dependencies": [{"default_features": False, "name": "normal-leaf"}],
                "features": {"default": ["required"], "required": []},
            },
            "build-helper": {
                "dependencies": [{"default_features": False, "name": "build-leaf"}],
                "features": {"default": ["required"], "required": []},
            },
            "normal-leaf": {},
            "build-leaf": {},
            "unused": {},
            "unused-build": {},
        },
        [{"name": "inactive", "target": 'cfg(target_os = "windows")'}],
        [linux, macos],
        [linux, macos],
    )

    for resolutions in [got.feature_resolutions_by_fq_crate] + [execution.resolutions for execution in got.exec_resolutions_by_cargo_target_triple.values()]:
        for name in ["inactive", "normal-helper", "build-helper", "normal-leaf", "build-leaf", "unused", "unused-build"]:
            resolution = resolutions[name + "-1.0.0"]
            asserts.equals(env, [], sorted(resolution.active))
            for platform_triple in [linux, macos]:
                asserts.equals(env, [], sorted(resolution.features_enabled[platform_triple]))
                asserts.equals(env, [], sorted(resolution.deps[platform_triple]))
                asserts.equals(env, [], sorted(resolution.build_deps[platform_triple]))
    for cargo_target_triple in [linux, macos]:
        asserts.equals(env, {}, got.exec_resolutions_by_cargo_target_triple[cargo_target_triple].build_deps)
    return unittest.end(env)

def _inactive_crates_do_not_change_active_features_impl(ctx):
    env = unittest.begin(ctx)
    linux = "x86_64-unknown-linux-gnu"
    macos = "aarch64-apple-darwin"
    got = _resolve_test_workspace(
        {
            "inactive": {
                "dependencies": [
                    {"default_features": False, "features": ["extra"], "name": "helper"},
                    {"default_features": False, "features": ["extra"], "kind": "build", "name": "helper"},
                ],
            },
            "helper": {
                "dependencies": [{"default_features": False, "name": "extra-leaf", "optional": True}],
                "features": {"extra": ["dep:extra-leaf"]},
            },
            "extra-leaf": {},
            "build-only": {"features": {"exec": []}},
        },
        [
            {"name": "inactive", "target": 'cfg(target_os = "windows")'},
            {"name": "helper"},
            {"kind": "build", "name": "helper"},
            {"features": ["exec"], "kind": "build", "name": "build-only"},
        ],
        [linux, macos],
        [linux, macos],
    )

    helper = got.feature_resolutions_by_fq_crate["helper-1.0.0"]
    asserts.equals(env, [], sorted(got.feature_resolutions_by_fq_crate["build-only-1.0.0"].active))
    for resolutions in [got.feature_resolutions_by_fq_crate] + [execution.resolutions for execution in got.exec_resolutions_by_cargo_target_triple.values()]:
        for name in ["inactive", "extra-leaf"]:
            asserts.equals(env, [], sorted(resolutions[name + "-1.0.0"].active))
    for cargo_target_triple in [linux, macos]:
        asserts.equals(env, [], sorted(helper.features_enabled[cargo_target_triple]))
        asserts.equals(env, [], sorted(helper.deps[cargo_target_triple]))
        for exec_platform_triple in [linux, macos]:
            execution = got.exec_resolutions_by_cargo_target_triple[cargo_target_triple].resolutions["helper-1.0.0"]
            asserts.equals(env, [], sorted(execution.features_enabled[exec_platform_triple]))
            asserts.equals(env, [], sorted(execution.deps[exec_platform_triple]))
            asserts.equals(env, ["exec"], sorted(got.exec_resolutions_by_cargo_target_triple[cargo_target_triple].resolutions["build-only-1.0.0"].features_enabled[exec_platform_triple]))
    return unittest.end(env)

def _inactive_annotations_do_not_activate_dependencies_impl(ctx):
    env = unittest.begin(ctx)
    linux = "x86_64-unknown-linux-gnu"
    macos = "aarch64-apple-darwin"
    got = _resolve_test_workspace(
        {
            "inactive": {
                "dependencies": [{"default_features": False, "kind": "build", "name": "helper", "optional": True}],
                "features": {"linux": ["helper/linux"], "macos": ["helper/macos"]},
            },
            "helper": {"features": {"linux": [], "macos": []}},
        },
        [{"name": "inactive", "target": 'cfg(target_os = "windows")'}],
        [linux, macos],
        [linux, macos],
        annotations = {"inactive": {"*": struct(
            crate_features = [],
            crate_features_select = {linux: ["linux"], macos: ["macos"]},
        )}},
    )

    for resolutions in [got.feature_resolutions_by_fq_crate] + [execution.resolutions for execution in got.exec_resolutions_by_cargo_target_triple.values()]:
        inactive = resolutions["inactive-1.0.0"]
        helper = resolutions["helper-1.0.0"]
        asserts.equals(env, [], sorted(inactive.active))
        asserts.equals(env, [], sorted(helper.active))
        for platform_triple, feature in [(linux, "linux"), (macos, "macos")]:
            asserts.equals(env, [feature], sorted(inactive.features_enabled[platform_triple]))
            asserts.equals(env, [], sorted(inactive.build_deps[platform_triple]))
            asserts.equals(env, [], sorted(helper.features_enabled[platform_triple]))
    for cargo_target_triple in [linux, macos]:
        asserts.equals(env, {}, got.exec_resolutions_by_cargo_target_triple[cargo_target_triple].build_deps)
    return unittest.end(env)

inactive_crates_remain_unresolved_test = unittest.make(_inactive_crates_remain_unresolved_impl)
inactive_crates_do_not_change_active_features_test = unittest.make(_inactive_crates_do_not_change_active_features_impl)
inactive_annotations_do_not_activate_dependencies_test = unittest.make(_inactive_annotations_do_not_activate_dependencies_impl)
resolve_cargo_workspace_members_isolates_forwarded_build_features_test = unittest.make(_resolve_cargo_workspace_members_isolates_forwarded_build_features_impl)
resolve_cargo_workspace_members_isolates_weak_build_features_test = unittest.make(_resolve_cargo_workspace_members_isolates_weak_build_features_impl)
resolve_cargo_workspace_members_groups_seeds_preserving_owners_test = unittest.make(_resolve_cargo_workspace_members_groups_seeds_preserving_owners_impl)
resolve_cargo_workspace_members_preserves_no_exec_resolution_test = unittest.make(_resolve_cargo_workspace_members_preserves_no_exec_resolution_impl)
optional_dependency_aliases_follow_enabled_features_test = unittest.make(_optional_dependency_aliases_follow_enabled_features_impl)

def cargo_workspace_graph_tests():
    return unittest.suite(
        "cargo_workspace_graph_tests",
        cargo_toml_dependencies_handles_workspace_inheritance_test,
        cargo_toml_dependencies_normalizes_dependency_specs_test,
        inactive_crates_remain_unresolved_test,
        inactive_crates_do_not_change_active_features_test,
        inactive_annotations_do_not_activate_dependencies_test,
        optional_dependency_aliases_follow_enabled_features_test,
        resolve_handles_dependency_chains_deeper_than_previous_round_limit_test,
        resolve_cargo_workspace_members_adds_requested_binary_target_roots_test,
        resolve_cargo_workspace_members_forwards_features_to_exec_only_build_deps_test,
        resolve_cargo_workspace_members_ignores_weak_features_for_unresolved_optional_deps_test,
        resolve_cargo_workspace_members_isolates_forwarded_build_features_test,
        resolve_cargo_workspace_members_isolates_weak_build_features_test,
        resolve_cargo_workspace_members_groups_seeds_preserving_owners_test,
        resolve_cargo_workspace_members_keeps_target_optional_build_deps_on_exec_platform_test,
        resolve_cargo_workspace_members_preserves_proc_macro_host_dependencies_test,
        resolve_cargo_workspace_members_preserves_no_exec_resolution_test,
        resolve_cargo_workspace_members_preserves_requested_binary_target_features_test,
        resolve_cargo_workspace_members_separates_target_and_exec_features_test,
        resolve_packages_attaches_feature_resolutions_test,
        select_package_dep_version_test,
        split_lockfile_packages_finds_local_package_paths_test,
    )
