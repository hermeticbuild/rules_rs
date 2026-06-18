load("@bazel_skylib//lib:unittest.bzl", "asserts", "unittest")
load(":cargo_workspace_graph.bzl", "cargo_toml_dependencies", "cargo_toml_fact", "classify_worlds", "compute_package_fq_deps", "render_world_views", "resolve_cargo_workspace_members", "resolve_package_facts", "select_package_fq_dep", "split_lockfile_packages", "workspace_dep_data")
load(":repository_utils.bzl", "render_rust_crate_call")

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
    )

    asserts.equals(env, {"serde": ["1.0.0"]}, got.versions_by_name)
    asserts.true(env, "feature_resolutions" in packages[0])
    asserts.equals(env, ["serde-1.0.0"], got.feature_resolutions_by_fq_crate.keys())
    return unittest.end(env)

resolve_package_facts_attaches_feature_resolutions_test = unittest.make(_resolve_package_facts_attaches_feature_resolutions_impl)

# --- feature-world split resolver tests --------------------------------------
#
# These drive resolve_package_facts + resolve_cargo_workspace_members end to
# end with small fixtures: `spoke_facts` maps fq crates to facts and `members`
# are cargo-metadata-style workspace packages ("lock_dependencies" is a
# harness-only key for the lockfile member entries). Fixtures are built inside
# each test so the resolver can mutate them (module-level values are frozen).

_LINUX = "x86_64-unknown-linux-gnu"
_DARWIN = "aarch64-apple-darwin"

def _noop(*_args, **_kwargs):
    pass

def _run_workspace_resolution(
        spoke_facts,
        members,
        triples = [_LINUX],
        annotations = {},
        proc_macro_spokes = []):
    packages = []
    for fq in spoke_facts:
        idx = fq.rfind("-")
        package = {"name": fq[:idx], "version": fq[idx + 1:]}
        if fq in proc_macro_spokes:
            package["is_proc_macro"] = True
        packages.append(package)

    resolved = resolve_package_facts(packages, spoke_facts, triples)

    workspace_members = [
        {
            "name": member["name"],
            "version": member["version"],
            "dependencies": member.get("lock_dependencies", []),
        }
        for member in members
    ]

    resolution = resolve_cargo_workspace_members(
        struct(report_progress = _noop, watch = _noop),
        cargo_metadata = {"packages": members},
        packages = packages,
        workspace_members = workspace_members,
        versions_by_name = resolved.versions_by_name,
        feature_resolutions_by_fq_crate = resolved.feature_resolutions_by_fq_crate,
        annotations = annotations,
        platform_triples = triples,
        materialize_workspace_members = False,
        validate_lockfile = False,
    )

    return struct(
        packages = packages,
        by_fq = resolved.feature_resolutions_by_fq_crate,
        resolution = resolution,
    )

def _target_features(result, fq, triple):
    return sorted(result.by_fq[fq].features_enabled[triple])

def _host_features(result, fq, triple):
    state = result.by_fq[fq].host["state"]
    if state == None:
        return None
    return sorted(state["features_enabled"][triple])

def _target_active(result, fq, triple):
    return result.by_fq[fq].target_active[triple]

def _host_active(result, fq, triple):
    state = result.by_fq[fq].host["state"]
    return state != None and state["active"][triple]

def _sqlx_shape_fixtures():
    # Minimal sqlx/rustls shape: a runtime root and a proc-macro both depend on
    # the same tls crate with different features.
    spoke_facts = {
        "macros-1.0.0": {
            "dependencies": [{"name": "tls", "features": ["light"], "default_features": False}],
            "features": {},
        },
        "tls-1.0.0": {
            "dependencies": [],
            "features": {"heavy": [], "light": []},
        },
    }
    members = [{
        "name": "app",
        "version": "0.1.0",
        "features": {},
        "targets": [{"kind": ["lib"]}],
        "dependencies": [
            {"name": "macros", "kind": None, "features": [], "uses_default_features": False},
            {"name": "tls", "kind": None, "features": ["heavy"], "uses_default_features": False},
        ],
        "lock_dependencies": ["macros", "tls"],
    }]
    return spoke_facts, members

def _split_sqlx_shape_impl(ctx):
    env = unittest.begin(ctx)

    spoke_facts, members = _sqlx_shape_fixtures()
    result = _run_workspace_resolution(spoke_facts, members, proc_macro_spokes = ["macros-1.0.0"])

    # Target world carries only the runtime root's request...
    asserts.true(env, _target_active(result, "tls-1.0.0", _LINUX))
    asserts.equals(env, ["heavy"], _target_features(result, "tls-1.0.0", _LINUX))

    # ...and the host world (under the proc-macro) only the macro's request.
    asserts.true(env, _host_active(result, "tls-1.0.0", _LINUX))
    asserts.equals(env, ["light"], _host_features(result, "tls-1.0.0", _LINUX))

    # The proc-macro itself is host-only: every edge to it crosses worlds.
    asserts.true(env, _host_active(result, "macros-1.0.0", _LINUX))
    asserts.false(env, _target_active(result, "macros-1.0.0", _LINUX))

    classes = classify_worlds(result.packages, [_LINUX])
    asserts.equals(env, "divergent", classes["tls-1.0.0"])
    asserts.equals(env, "host_only", classes["macros-1.0.0"])
    return unittest.end(env)

def _split_build_dep_crossing_and_stickiness_impl(ctx):
    env = unittest.begin(ctx)

    # The host root is a SPOKE's [build-dependencies] edge (member build edges
    # stay target-world — members are world boundaries).
    spoke_facts = {
        "wrapper-1.0.0": {"dependencies": [{"name": "gen", "kind": "build", "default_features": False}], "features": {}},
        "gen-1.0.0": {"dependencies": [{"name": "mid", "default_features": False}], "features": {}},
        "mid-1.0.0": {"dependencies": [{"name": "tls", "features": ["light"], "default_features": False}], "features": {}},
        "tls-1.0.0": {"dependencies": [], "features": {"heavy": [], "light": []}},
    }
    members = [{
        "name": "app",
        "version": "0.1.0",
        "features": {},
        "targets": [{"kind": ["lib"]}],
        "dependencies": [
            {"name": "wrapper", "kind": None, "features": [], "uses_default_features": False},
            {"name": "tls", "kind": None, "features": ["heavy"], "uses_default_features": False},
        ],
        "lock_dependencies": ["wrapper", "tls"],
    }]
    result = _run_workspace_resolution(spoke_facts, members)

    # The spoke build-dep edge crosses into the host world, and host-ness is
    # sticky down the normal-dep chain gen -> mid -> tls.
    for fq in ["gen-1.0.0", "mid-1.0.0"]:
        asserts.true(env, _host_active(result, fq, _LINUX))
        asserts.false(env, _target_active(result, fq, _LINUX))

    asserts.equals(env, ["light"], _host_features(result, "tls-1.0.0", _LINUX))
    asserts.equals(env, ["heavy"], _target_features(result, "tls-1.0.0", _LINUX))

    # Bucket routing: wrapper's target view records the build-dep label in its
    # build_deps bucket; gen's host view records mid in its deps bucket.
    asserts.true(env, "//:gen-1.0.0" in result.by_fq["wrapper-1.0.0"].build_deps[_LINUX])
    asserts.true(env, "//:mid-1.0.0" in result.by_fq["gen-1.0.0"].host["state"]["deps"][_LINUX])

    classes = classify_worlds(result.packages, [_LINUX])
    asserts.equals(env, "host_only", classes["gen-1.0.0"])
    asserts.equals(env, "host_only", classes["mid-1.0.0"])
    asserts.equals(env, "divergent", classes["tls-1.0.0"])
    return unittest.end(env)

def _split_member_proc_macro_is_world_boundary_impl(ctx):
    env = unittest.begin(ctx)

    # Proc-macro MEMBERS are world boundaries, NOT host roots: their
    # gazelle-owned single-instance targets mix DEP_DATA labels with
    # member-to-member labels and hand-written pins, so all their deps must
    # resolve in the target world. (Proc-macro SPOKES remain host roots —
    # covered by the sqlx-shape test.)
    spoke_facts = {
        "tls-1.0.0": {"dependencies": [], "features": {"heavy": [], "light": []}},
        "devdep-1.0.0": {"dependencies": [], "features": {"testing": []}},
    }
    members = [{
        "name": "pm",
        "version": "0.1.0",
        "features": {"default": []},
        "targets": [{"kind": ["proc-macro"]}],
        "dependencies": [
            {"name": "tls", "kind": None, "features": ["light"], "uses_default_features": False},
            {"name": "devdep", "kind": "dev", "features": ["testing"], "uses_default_features": False},
        ],
        "lock_dependencies": ["tls", "devdep"],
    }]
    result = _run_workspace_resolution(spoke_facts, members)

    # The proc-macro member is a target-world root: activation and the
    # "default" self-seed stay target-side, no host state is ever allocated.
    asserts.true(env, _target_active(result, "pm-0.1.0", _LINUX))
    asserts.equals(env, None, result.by_fq["pm-0.1.0"].host["state"])
    asserts.equals(env, ["default"], _target_features(result, "pm-0.1.0", _LINUX))

    # Its normal deps resolve in the target world (base instances)...
    asserts.true(env, _target_active(result, "tls-1.0.0", _LINUX))
    asserts.equals(env, None, result.by_fq["tls-1.0.0"].host["state"])
    asserts.equals(env, ["light"], _target_features(result, "tls-1.0.0", _LINUX))

    # ...and so do its dev deps.
    asserts.true(env, _target_active(result, "devdep-1.0.0", _LINUX))
    asserts.equals(env, ["testing"], _target_features(result, "devdep-1.0.0", _LINUX))
    asserts.equals(env, None, result.by_fq["devdep-1.0.0"].host["state"])
    return unittest.end(env)

def _split_multi_kind_dep_feature_forwarding_impl(ctx):
    env = unittest.begin(ctx)

    spoke_facts = {
        "p-1.0.0": {
            "dependencies": [
                {"name": "pshared", "default_features": False},
                {"name": "pshared", "kind": "build", "default_features": False},
            ],
            "features": {"f": ["pshared/feat"]},
        },
        "q-1.0.0": {
            "dependencies": [
                {"name": "qshared", "default_features": False},
                {"name": "qshared", "kind": "build", "default_features": False},
            ],
            "features": {"f": ["qshared/feat"]},
        },
        "pshared-1.0.0": {"dependencies": [], "features": {"feat": []}},
        "qshared-1.0.0": {"dependencies": [], "features": {"feat": []}},
        "wrapper-1.0.0": {"dependencies": [{"name": "q", "kind": "build", "features": ["f"], "default_features": False}], "features": {}},
    }
    members = [{
        "name": "app",
        "version": "0.1.0",
        "features": {},
        "targets": [{"kind": ["lib"]}],
        "dependencies": [
            {"name": "p", "kind": None, "features": ["f"], "uses_default_features": False},
            {"name": "wrapper", "kind": None, "features": [], "uses_default_features": False},
        ],
        "lock_dependencies": ["p", "wrapper"],
    }]
    result = _run_workspace_resolution(spoke_facts, members)

    # p is target-active with `f`. Its `pshared/feat` must reach BOTH worlds:
    # via the [dependencies] entry (sticky target) AND via the
    # [build-dependencies] entry (host) — the unified resolver's first-match
    # `break` would forward through only one entry.
    asserts.true(env, _target_active(result, "pshared-1.0.0", _LINUX))
    asserts.true(env, _host_active(result, "pshared-1.0.0", _LINUX))
    asserts.equals(env, ["feat"], _target_features(result, "pshared-1.0.0", _LINUX))
    asserts.equals(env, ["feat"], _host_features(result, "pshared-1.0.0", _LINUX))

    # q is host-active with `f`: both of its entries forward into the host
    # world only, so qshared never gains a target instance.
    asserts.true(env, _host_active(result, "q-1.0.0", _LINUX))
    asserts.false(env, _target_active(result, "q-1.0.0", _LINUX))
    asserts.true(env, _host_active(result, "qshared-1.0.0", _LINUX))
    asserts.false(env, _target_active(result, "qshared-1.0.0", _LINUX))
    asserts.equals(env, ["feat"], _host_features(result, "qshared-1.0.0", _LINUX))
    asserts.equals(env, [], _target_features(result, "qshared-1.0.0", _LINUX))
    return unittest.end(env)

def _split_optional_weak_features_per_world_impl(ctx):
    env = unittest.begin(ctx)

    spoke_facts = {
        "p-1.0.0": {
            "dependencies": [
                {"name": "tlsdep", "optional": True, "default_features": False},
            ],
            "features": {
                "f": ["dep:tlsdep", "tlsdep?/light"],
                "h": ["tlsdep?/heavy"],
            },
        },
        "tlsdep-1.0.0": {"dependencies": [], "features": {"heavy": [], "light": []}},
        "wrapper-1.0.0": {"dependencies": [{"name": "p", "kind": "build", "features": ["f"], "default_features": False}], "features": {}},
    }
    members = [{
        "name": "app",
        "version": "0.1.0",
        "features": {},
        "targets": [{"kind": ["lib"]}],
        "dependencies": [
            {"name": "p", "kind": None, "features": ["h"], "uses_default_features": False},
            {"name": "wrapper", "kind": None, "features": [], "uses_default_features": False},
        ],
        "lock_dependencies": ["p", "wrapper"],
    }]
    result = _run_workspace_resolution(spoke_facts, members)

    # Host world: `f` enables dep:tlsdep, so the optional dep activates there
    # and the weak `tlsdep?/light` forwards.
    asserts.true(env, _host_active(result, "tlsdep-1.0.0", _LINUX))
    asserts.equals(env, ["light"], _host_features(result, "tlsdep-1.0.0", _LINUX))

    # Target world: `h` only weak-references the never-enabled optional dep, so
    # tlsdep is NOT activated there and "heavy" lands nowhere.
    asserts.false(env, _target_active(result, "tlsdep-1.0.0", _LINUX))
    asserts.equals(env, [], _target_features(result, "tlsdep-1.0.0", _LINUX))

    # p itself is active in both worlds with differing views.
    classes = classify_worlds(result.packages, [_LINUX])
    asserts.equals(env, "divergent", classes["p-1.0.0"])
    asserts.equals(env, "host_only", classes["tlsdep-1.0.0"])
    return unittest.end(env)

def _split_disjoint_triple_activity_impl(ctx):
    env = unittest.begin(ctx)

    triples = [_LINUX, _DARWIN]
    spoke_facts = {
        "shared-1.0.0": {"dependencies": [], "features": {"heavy": [], "light": []}},
        "wrapper-1.0.0": {
            "dependencies": [{"name": "shared", "kind": "build", "features": ["light"], "default_features": False, "target": "cfg(target_os = \"linux\")"}],
            "features": {},
        },
    }
    members = [{
        "name": "app",
        "version": "0.1.0",
        "features": {},
        "targets": [{"kind": ["lib"]}],
        "dependencies": [
            {"name": "wrapper", "kind": None, "features": [], "uses_default_features": False},
            {"name": "shared", "kind": None, "features": ["heavy"], "uses_default_features": False, "target": "cfg(target_os = \"macos\")"},
        ],
        "lock_dependencies": ["shared", "wrapper"],
    }]
    result = _run_workspace_resolution(spoke_facts, members, triples = triples)

    # Host-active on linux only (wrapper's cfg-gated build-dep), target-active
    # on darwin only (cfg-gated normal dep) — with different feature views.
    asserts.true(env, _host_active(result, "shared-1.0.0", _LINUX))
    asserts.false(env, _host_active(result, "shared-1.0.0", _DARWIN))
    asserts.false(env, _target_active(result, "shared-1.0.0", _LINUX))
    asserts.true(env, _target_active(result, "shared-1.0.0", _DARWIN))
    asserts.equals(env, ["light"], _host_features(result, "shared-1.0.0", _LINUX))
    asserts.equals(env, ["heavy"], _target_features(result, "shared-1.0.0", _DARWIN))

    # No triple is active in both worlds, so there is nothing to compare: NOT
    # divergent. The base target renders the per-triple world-merged view.
    classes = classify_worlds(result.packages, triples)
    asserts.equals(env, "identical", classes["shared-1.0.0"])
    return unittest.end(env)

def _split_deep_chain_converges_impl(ctx):
    env = unittest.begin(ctx)

    chain_length = 60
    spoke_facts = {}
    for i in range(chain_length):
        dependencies = []
        if i + 1 < chain_length:
            dependencies.append({"name": "c%d" % (i + 1), "default_features": False})
        spoke_facts["c%d-1.0.0" % i] = {"dependencies": dependencies, "features": {}}
    spoke_facts["wrapper-1.0.0"] = {"dependencies": [{"name": "c0", "kind": "build", "default_features": False}], "features": {}}

    members = [{
        "name": "app",
        "version": "0.1.0",
        "features": {},
        "targets": [{"kind": ["lib"]}],
        "dependencies": [
            {"name": "wrapper", "kind": None, "features": [], "uses_default_features": False},
        ],
        "lock_dependencies": ["wrapper"],
    }]
    result = _run_workspace_resolution(spoke_facts, members)

    deepest = "c%d-1.0.0" % (chain_length - 1)
    asserts.true(env, _host_active(result, deepest, _LINUX))
    asserts.false(env, _target_active(result, deepest, _LINUX))

    # Worklist draining: activation does not consume a round per dependency
    # level. The 60-deep chain must converge in a handful of rounds (bounded by
    # the feature-implication chain), nowhere near _MAX_ROUNDS = 50.
    asserts.true(env, result.resolution.resolution_rounds <= 4)
    return unittest.end(env)

def _split_build_dep_chain_activation_drain_impl(ctx):
    env = unittest.begin(ctx)

    spoke_facts = {
        "b0-1.0.0": {"dependencies": [{"name": "b1", "kind": "build", "default_features": False}], "features": {}},
        "b1-1.0.0": {"dependencies": [{"name": "b2", "kind": "build", "default_features": False}], "features": {}},
        "b2-1.0.0": {"dependencies": [{"name": "b3", "kind": "build", "default_features": False}], "features": {}},
        "b3-1.0.0": {"dependencies": [], "features": {}},
        "wrapper-1.0.0": {"dependencies": [{"name": "b0", "kind": "build", "default_features": False}], "features": {}},
    }
    members = [{
        "name": "app",
        "version": "0.1.0",
        "features": {},
        "targets": [{"kind": ["lib"]}],
        "dependencies": [
            {"name": "wrapper", "kind": None, "features": [], "uses_default_features": False},
        ],
        "lock_dependencies": ["wrapper"],
    }]
    result = _run_workspace_resolution(spoke_facts, members)

    # The whole chain of build-dep crossings activates within one resolve()
    # call's in-round drain.
    for fq in ["b0-1.0.0", "b1-1.0.0", "b2-1.0.0", "b3-1.0.0"]:
        asserts.true(env, _host_active(result, fq, _LINUX))
        asserts.false(env, _target_active(result, fq, _LINUX))
    asserts.true(env, result.resolution.resolution_rounds <= 3)
    return unittest.end(env)

def _split_annotations_seed_without_activation_impl(ctx):
    env = unittest.begin(ctx)

    spoke_facts = {
        "buildtool-1.0.0": {
            "dependencies": [{"name": "transitive_tool", "default_features": False}],
            "features": {"annofeat": [], "seeded": []},
        },
        "transitive_tool-1.0.0": {"dependencies": [], "features": {"annofeat": []}},
        "lonely-1.0.0": {"dependencies": [], "features": {"annofeat": []}},
        "wrapper-1.0.0": {"dependencies": [{"name": "buildtool", "kind": "build", "features": ["seeded"], "default_features": False}], "features": {}},
    }
    members = [{
        "name": "app",
        "version": "0.1.0",
        "features": {},
        "targets": [{"kind": ["lib"]}],
        "dependencies": [
            {"name": "wrapper", "kind": None, "features": [], "uses_default_features": False},
        ],
        "lock_dependencies": ["wrapper"],
    }]
    annotation = struct(crate_features = ["annofeat"], crate_features_select = {})
    annotations = {
        "buildtool": {"*": annotation},
        "lonely": {"*": annotation},
        "transitive_tool": {"*": annotation},
    }
    result = _run_workspace_resolution(spoke_facts, members, annotations = annotations)

    # Annotations seed BOTH worlds: pending host seeds are copied when the
    # fixpoint first host-activates the crate (copy-on-activate)...
    asserts.equals(env, ["annofeat", "seeded"], _host_features(result, "buildtool-1.0.0", _LINUX))
    asserts.equals(env, ["annofeat"], _target_features(result, "buildtool-1.0.0", _LINUX))

    # ...including transitively host-reached crates.
    asserts.true(env, _host_active(result, "transitive_tool-1.0.0", _LINUX))
    asserts.equals(env, ["annofeat"], _host_features(result, "transitive_tool-1.0.0", _LINUX))

    # But annotations never ACTIVATE a world: the never-referenced crate
    # allocates no host state and stays inactive everywhere.
    asserts.equals(env, None, result.by_fq["lonely-1.0.0"].host["state"])
    asserts.equals(env, ["annofeat"], _target_features(result, "lonely-1.0.0", _LINUX))
    asserts.false(env, _target_active(result, "lonely-1.0.0", _LINUX))

    classes = classify_worlds(result.packages, [_LINUX])
    asserts.equals(env, "unactivated", classes["lonely-1.0.0"])
    asserts.equals(env, "host_only", classes["buildtool-1.0.0"])
    asserts.equals(env, "host_only", classes["transitive_tool-1.0.0"])
    return unittest.end(env)

def _split_transitive_label_divergence_impl(ctx):
    env = unittest.begin(ctx)

    spoke_facts = {
        "macros-1.0.0": {"dependencies": [{"name": "m", "default_features": False}], "features": {}},
        "m-1.0.0": {"dependencies": [{"name": "r", "default_features": False}], "features": {}},
        "r-1.0.0": {"dependencies": [], "features": {"heavy": []}},
    }
    members = [{
        "name": "app",
        "version": "0.1.0",
        "features": {},
        "targets": [{"kind": ["lib"]}],
        "dependencies": [
            {"name": "macros", "kind": None, "features": [], "uses_default_features": False},
            {"name": "m", "kind": None, "features": [], "uses_default_features": False},
            {"name": "r", "kind": None, "features": ["heavy"], "uses_default_features": False},
        ],
        "lock_dependencies": ["m", "macros", "r"],
    }]
    result = _run_workspace_resolution(spoke_facts, members, proc_macro_spokes = ["macros-1.0.0"])

    # m's per-world feature views are identical (both empty), and so are its
    # per-world dep label sets pre-rewrite...
    asserts.equals(env, [], _target_features(result, "m-1.0.0", _LINUX))
    asserts.equals(env, [], _host_features(result, "m-1.0.0", _LINUX))
    asserts.true(env, "//:r-1.0.0" in result.by_fq["m-1.0.0"].host["state"]["deps"][_LINUX])

    # ...but r is divergent (target gained the runtime-only "heavy"), so m's
    # host instance must become label-divergent: post-rewrite its host dep
    # labels differ (r_host vs r). The proc-macro stays host-only and does NOT
    # propagate further (its base target already renders the host view).
    classes = classify_worlds(result.packages, [_LINUX])
    asserts.equals(env, "divergent", classes["r-1.0.0"])
    asserts.equals(env, "label_divergent", classes["m-1.0.0"])
    asserts.equals(env, "host_only", classes["macros-1.0.0"])
    return unittest.end(env)

def _proc_macro_bit_plumbing_impl(ctx):
    env = unittest.begin(ctx)

    # cargo_toml_fact records [lib] proc-macro = true from real manifests.
    fact = cargo_toml_fact({"package": {"name": "x"}, "lib": {"proc-macro": True}})
    asserts.true(env, fact["is_proc_macro"])
    fact = cargo_toml_fact({"package": {"name": "x"}})
    asserts.false(env, fact["is_proc_macro"])

    # resolve_package_facts: a bit stamped on the package dict (the
    # proc_macro_packages JSON override) wins over the fact's manifest bit.
    packages = [
        {"name": "a", "version": "1.0.0", "is_proc_macro": True},
        {"name": "b", "version": "1.0.0"},
        {"name": "c", "version": "1.0.0", "is_proc_macro": False},
    ]
    resolve_package_facts(
        packages,
        {
            "a-1.0.0": {},
            "b-1.0.0": {"is_proc_macro": True},
            "c-1.0.0": {"is_proc_macro": True},
        },
        [_LINUX],
    )
    asserts.true(env, packages[0]["feature_resolutions"].is_proc_macro)
    asserts.true(env, packages[1]["feature_resolutions"].is_proc_macro)
    asserts.false(env, packages[2]["feature_resolutions"].is_proc_macro)
    return unittest.end(env)

def _render_world_views_divergence_impl(ctx):
    env = unittest.begin(ctx)

    # Same shape as the transitive-label-divergence test: app -> m -> r with
    # app -> r (heavy) and a proc-macro chain macros -> m -> r.
    spoke_facts = {
        "macros-1.0.0": {"dependencies": [{"name": "m", "default_features": False}], "features": {}},
        "m-1.0.0": {"dependencies": [{"name": "r", "default_features": False}], "features": {}},
        "r-1.0.0": {"dependencies": [], "features": {"heavy": []}},
    }
    members = [{
        "name": "app",
        "version": "0.1.0",
        "features": {},
        "targets": [{"kind": ["lib"]}],
        "dependencies": [
            {"name": "macros", "kind": None, "features": [], "uses_default_features": False},
            {"name": "m", "kind": None, "features": [], "uses_default_features": False},
            {"name": "r", "kind": None, "features": ["heavy"], "uses_default_features": False},
        ],
        "lock_dependencies": ["m", "macros", "r"],
    }]
    result = _run_workspace_resolution(spoke_facts, members, proc_macro_spokes = ["macros-1.0.0"])
    classes = classify_worlds(result.packages, [_LINUX])

    # Divergent leaf: base view is the target instance, host views rendered.
    views_r = render_world_views(result.by_fq["r-1.0.0"], classes["r-1.0.0"], classes, [_LINUX])
    asserts.equals(env, ["heavy"], sorted(views_r.crate_features[_LINUX]))
    asserts.equals(env, [], sorted(views_r.host_crate_features[_LINUX]))
    asserts.false(env, views_r.unactivated)

    # Label-divergent middle: identical per-world feature views, but the host
    # instance's dep labels point at the _host sibling of the divergent dep.
    views_m = render_world_views(result.by_fq["m-1.0.0"], classes["m-1.0.0"], classes, [_LINUX])
    asserts.equals(env, ["//:r-1.0.0"], sorted(views_m.deps[_LINUX]))
    asserts.equals(env, ["//:r-1.0.0_host"], sorted(views_m.host_deps[_LINUX]))
    asserts.equals(env, [], sorted(views_m.host_crate_features[_LINUX]))

    # Host-only proc-macro: NO _host sibling (base name carries the host view),
    # but its base deps still link the label-divergent middle's _host variant.
    views_macros = render_world_views(result.by_fq["macros-1.0.0"], classes["macros-1.0.0"], classes, [_LINUX])
    asserts.equals(env, None, views_macros.host_crate_features)
    asserts.equals(env, ["//:m-1.0.0_host"], sorted(views_macros.deps[_LINUX]))
    return unittest.end(env)

def _render_world_views_target_only_build_dep_rewrite_impl(ctx):
    env = unittest.begin(ctx)

    # P is target-only, but its [build-dependencies] subtree is host world:
    # the build-dep label on divergent tls must point at tls's _host sibling.
    spoke_facts = {
        "p-1.0.0": {"dependencies": [{"name": "tls", "kind": "build", "features": ["light"], "default_features": False}], "features": {}},
        "tls-1.0.0": {"dependencies": [], "features": {"heavy": [], "light": []}},
    }
    members = [{
        "name": "app",
        "version": "0.1.0",
        "features": {},
        "targets": [{"kind": ["lib"]}],
        "dependencies": [
            {"name": "p", "kind": None, "features": [], "uses_default_features": False},
            {"name": "tls", "kind": None, "features": ["heavy"], "uses_default_features": False},
        ],
        "lock_dependencies": ["p", "tls"],
    }]
    result = _run_workspace_resolution(spoke_facts, members)
    classes = classify_worlds(result.packages, [_LINUX])
    asserts.equals(env, "target_only", classes["p-1.0.0"])
    asserts.equals(env, "divergent", classes["tls-1.0.0"])

    views_p = render_world_views(result.by_fq["p-1.0.0"], classes["p-1.0.0"], classes, [_LINUX])
    asserts.equals(env, ["//:tls-1.0.0_host"], sorted(views_p.build_deps[_LINUX]))
    asserts.equals(env, [], sorted(views_p.deps[_LINUX]))

    # No host instance for a target-only crate.
    asserts.equals(env, None, views_p.host_crate_features)
    return unittest.end(env)

def _render_world_views_disjoint_triple_merge_impl(ctx):
    env = unittest.begin(ctx)

    triples = [_LINUX, _DARWIN]
    spoke_facts = {
        "shared-1.0.0": {"dependencies": [], "features": {"heavy": [], "light": []}},
        "wrapper-1.0.0": {
            "dependencies": [{"name": "shared", "kind": "build", "features": ["light"], "default_features": False, "target": "cfg(target_os = \"linux\")"}],
            "features": {},
        },
    }
    members = [{
        "name": "app",
        "version": "0.1.0",
        "features": {},
        "targets": [{"kind": ["lib"]}],
        "dependencies": [
            {"name": "wrapper", "kind": None, "features": [], "uses_default_features": False},
            {"name": "shared", "kind": None, "features": ["heavy"], "uses_default_features": False, "target": "cfg(target_os = \"macos\")"},
        ],
        "lock_dependencies": ["shared", "wrapper"],
    }]
    result = _run_workspace_resolution(spoke_facts, members, triples = triples)
    classes = classify_worlds(result.packages, triples)
    asserts.equals(env, "identical", classes["shared-1.0.0"])

    # The base target renders the per-triple world merge: host view on the
    # host-only-active triple, target view on the target-active triple.
    views = render_world_views(result.by_fq["shared-1.0.0"], classes["shared-1.0.0"], classes, triples)
    asserts.equals(env, ["light"], sorted(views.crate_features[_LINUX]))
    asserts.equals(env, ["heavy"], sorted(views.crate_features[_DARWIN]))
    asserts.equals(env, None, views.host_crate_features)
    return unittest.end(env)

def _render_world_views_unactivated_impl(ctx):
    env = unittest.begin(ctx)

    spoke_facts = {
        "lonely-1.0.0": {"dependencies": [], "features": {"annofeat": []}},
        "used-1.0.0": {"dependencies": [], "features": {}},
    }
    members = [{
        "name": "app",
        "version": "0.1.0",
        "features": {},
        "targets": [{"kind": ["lib"]}],
        "dependencies": [
            {"name": "used", "kind": None, "features": [], "uses_default_features": False},
        ],
        "lock_dependencies": ["used"],
    }]
    annotations = {"lonely": {"*": struct(crate_features = ["annofeat"], crate_features_select = {})}}
    result = _run_workspace_resolution(spoke_facts, members, annotations = annotations)
    classes = classify_worlds(result.packages, [_LINUX])
    asserts.equals(env, "unactivated", classes["lonely-1.0.0"])

    # The loud stub: no features/deps rendered (even annotation seeds — cargo
    # would not build this crate at all).
    views = render_world_views(result.by_fq["lonely-1.0.0"], classes["lonely-1.0.0"], classes, [_LINUX])
    asserts.true(env, views.unactivated)
    asserts.equals(env, [], sorted(views.crate_features[_LINUX]))
    asserts.equals(env, None, views.host_crate_features)

    views_used = render_world_views(result.by_fq["used-1.0.0"], classes["used-1.0.0"], classes, [_LINUX])
    asserts.false(env, views_used.unactivated)
    return unittest.end(env)

def _workspace_dep_data_member_world_boundary_impl(ctx):
    env = unittest.begin(ctx)

    # Members are world boundaries: their gazelle-owned single-instance
    # targets mix DEP_DATA labels with member-to-member labels and
    # hand-written `@crates//:x` pins, so one action may only ever see ONE
    # instance of each crate. Even when a member has a build-dep on a
    # DIVERGENT crate plus a build-dep on another member (the
    # tonic-to-json-tests E0464 shape), DEP_DATA must render base labels —
    # never `_host`.
    spoke_facts = {
        "macros-1.0.0": {"dependencies": [{"name": "tls", "features": ["light"], "default_features": False}], "features": {}},
        "tls-1.0.0": {"dependencies": [], "features": {"heavy": [], "light": []}},
        "devdep-1.0.0": {"dependencies": [], "features": {}},
    }
    members = [
        {
            "name": "app",
            "version": "0.1.0",
            "features": {},
            "targets": [{"kind": ["lib"]}],
            "manifest_path": "/repo/app/Cargo.toml",
            "dependencies": [
                {"name": "tls", "kind": None, "features": ["heavy"], "uses_default_features": False},
                {"name": "macros", "kind": None, "features": [], "uses_default_features": False},
                # Build-dep on a divergent crate + build-dep on another member.
                {"name": "tls", "kind": "build", "features": ["light"], "uses_default_features": False},
                {"name": "libmember", "kind": "build", "features": [], "uses_default_features": False, "path": "/repo/libmember"},
            ],
            "lock_dependencies": ["tls", "macros", "libmember"],
        },
        {
            "name": "libmember",
            "version": "0.1.0",
            "features": {},
            "targets": [{"kind": ["lib"]}],
            "manifest_path": "/repo/libmember/Cargo.toml",
            "dependencies": [
                {"name": "tls", "kind": None, "features": ["heavy"], "uses_default_features": False},
            ],
            "lock_dependencies": ["tls"],
        },
        {
            "name": "pmm",
            "version": "0.1.0",
            "features": {"default": []},
            "targets": [{"kind": ["proc-macro"]}],
            "manifest_path": "/repo/pmm/Cargo.toml",
            "dependencies": [
                {"name": "tls", "kind": None, "features": [], "uses_default_features": False},
                {"name": "devdep", "kind": "dev", "features": [], "uses_default_features": False},
            ],
            "lock_dependencies": ["tls", "devdep"],
        },
    ]
    result = _run_workspace_resolution(spoke_facts, members, proc_macro_spokes = ["macros-1.0.0"])

    # tls IS divergent (host world via the proc-macro SPOKE only carries
    # "light"); the member build-dep's "light" lands in the TARGET set.
    classes = classify_worlds(result.packages, [_LINUX])
    asserts.equals(env, "divergent", classes["tls-1.0.0"])
    asserts.equals(env, ["heavy", "light"], _target_features(result, "tls-1.0.0", _LINUX))
    asserts.equals(env, ["light"], _host_features(result, "tls-1.0.0", _LINUX))

    # Members are never host-activated.
    for member_fq in ["app-0.1.0", "libmember-0.1.0", "pmm-0.1.0"]:
        asserts.equals(env, None, result.by_fq[member_fq].host["state"])

    dep_data = workspace_dep_data(
        cargo_metadata = {"packages": members},
        feature_resolutions_by_fq_crate = result.by_fq,
        platform_triples = [_LINUX],
        platform_cfg_attrs = result.resolution.platform_cfg_attrs,
        cfg_match_cache = result.resolution.cfg_match_cache,
        repo_root = "/repo",
        workspace_package = "",
        use_legacy_rules_rust_platforms = False,
    )

    # Build-dep buckets keep BASE labels (the divergent crate AND the member),
    # so a member build script's action links one coherent world.
    asserts.equals(env, ["//:tls-1.0.0", "//libmember"], dep_data["app"]["build_deps"])
    asserts.equals(env, ["//:macros-1.0.0", "//:tls-1.0.0"], dep_data["app"]["deps"])

    # Proc-macro members render the target view too.
    asserts.equals(env, ["//:tls-1.0.0"], dep_data["pmm"]["deps"])
    asserts.equals(env, ["//:devdep-1.0.0"], dep_data["pmm"]["dev_deps"])
    asserts.equals(env, ["default"], dep_data["pmm"]["crate_features"])

    # No `_host` label may ever reach DEP_DATA, in any bucket of any member.
    for member_dep_data in dep_data.values():
        for bucket in ["build_deps", "deps", "dev_deps"]:
            for label in member_dep_data[bucket]:
                asserts.false(env, label.endswith("_host"))
        for labels in (member_dep_data["build_deps_by_platform"].values() +
                       member_dep_data["deps_by_platform"].values() +
                       member_dep_data["dev_deps_by_platform"].values()):
            for label in labels:
                asserts.false(env, label.endswith("_host"))
    return unittest.end(env)

def _split_host_deps_view_completeness_impl(ctx):
    env = unittest.begin(ctx)

    # Regression shapes from end-to-end validation on a large Cargo workspace:
    # - chacha (rand_chacha shape): divergent crate with a NON-optional dep —
    #   the dep must carry into the _host views at every host-active triple.
    # - common (crypto-common shape): OPTIONAL dep activated in the host world
    #   via its eponymous feature — it must appear in the host deps view at
    #   every host-active triple (and NOT in the target view).
    triples = [_LINUX, _DARWIN]
    spoke_facts = {
        "chacha-1.0.0": {
            "dependencies": [{"name": "core", "default_features": False}],
            "features": {"std": ["core/std"]},
        },
        "common-1.0.0": {
            "dependencies": [
                {"name": "garray", "default_features": False},
                {"name": "core", "optional": True, "default_features": False},
            ],
            "features": {},
        },
        "core-1.0.0": {"dependencies": [], "features": {"std": []}},
        "garray-1.0.0": {"dependencies": [], "features": {}},
        "wrapper-1.0.0": {
            "dependencies": [
                {"name": "chacha", "kind": "build", "features": ["std"], "default_features": False},
                {"name": "common", "kind": "build", "features": ["core"], "default_features": False},
            ],
            "features": {},
        },
    }
    members = [{
        "name": "app",
        "version": "0.1.0",
        "features": {},
        "targets": [{"kind": ["lib"]}],
        "dependencies": [
            # Target instances without the extra features...
            {"name": "chacha", "kind": None, "features": [], "uses_default_features": False},
            {"name": "common", "kind": None, "features": [], "uses_default_features": False},
            # ...host instances (via the wrapper spoke's build-deps) with
            # them, so both crates classify divergent.
            {"name": "wrapper", "kind": None, "features": [], "uses_default_features": False},
        ],
        "lock_dependencies": ["chacha", "common", "wrapper"],
    }]
    result = _run_workspace_resolution(spoke_facts, members, triples = triples)
    classes = classify_worlds(result.packages, triples)
    asserts.equals(env, "divergent", classes["chacha-1.0.0"])
    asserts.equals(env, "divergent", classes["common-1.0.0"])

    # core's host instance gained "std" (via chacha's host-world `core/std`)
    # while its target instance did not: divergent, so host edges rewrite.
    asserts.equals(env, "divergent", classes["core-1.0.0"])
    asserts.equals(env, "identical", classes["garray-1.0.0"])

    views_chacha = render_world_views(result.by_fq["chacha-1.0.0"], classes["chacha-1.0.0"], classes, triples)
    views_common = render_world_views(result.by_fq["common-1.0.0"], classes["common-1.0.0"], classes, triples)

    for triple in triples:
        # Resolver layer: the host dep buckets are complete at every
        # host-active triple.
        asserts.true(env, "//:core-1.0.0" in result.by_fq["chacha-1.0.0"].host["state"]["deps"][triple])
        asserts.true(env, "//:core-1.0.0" in result.by_fq["common-1.0.0"].host["state"]["deps"][triple])

        # Render layer: non-optional dep present in _host views (rewritten to
        # the divergent dep's _host sibling).
        asserts.equals(env, ["//:core-1.0.0_host"], sorted(views_chacha.host_deps[triple]))

        # Optional dep activated by the host-world feature: present in the
        # host view, absent from the target view.
        asserts.equals(env, ["//:core-1.0.0_host", "//:garray-1.0.0"], sorted(views_common.host_deps[triple]))
        asserts.equals(env, ["//:garray-1.0.0"], sorted(views_common.deps[triple]))
        asserts.true(env, "core" in views_common.host_crate_features[triple])
    return unittest.end(env)

def _split_optional_dep_target_enablement_does_not_cross_impl(ctx):
    env = unittest.begin(ctx)

    # reqwest/hickory-dns shape: crate rq has an optional dep hick behind
    # feature "dns". A TARGET-world consumer enables rq with "dns"; a
    # HOST-world consumer uses rq WITHOUT it. The optional-dep gate and the
    # dep: marker must stay per-world: hick must NOT host-activate.
    spoke_facts = {
        "rq-1.0.0": {
            "dependencies": [
                {"name": "hick", "optional": True, "default_features": False},
            ],
            "features": {"dns": ["dep:hick"]},
        },
        "hick-1.0.0": {"dependencies": [], "features": {}},
        "wrapper-1.0.0": {"dependencies": [{"name": "rq", "kind": "build", "default_features": False}], "features": {}},
    }
    members = [{
        "name": "app",
        "version": "0.1.0",
        "features": {},
        "targets": [{"kind": ["lib"]}],
        "dependencies": [
            {"name": "rq", "kind": None, "features": ["dns"], "uses_default_features": False},
            {"name": "wrapper", "kind": None, "features": [], "uses_default_features": False},
        ],
        "lock_dependencies": ["rq", "wrapper"],
    }]
    result = _run_workspace_resolution(spoke_facts, members)

    # Target world: dns -> dep:hick -> optional dep activated.
    asserts.true(env, _target_active(result, "hick-1.0.0", _LINUX))
    asserts.true(env, "dep:hick" in result.by_fq["rq-1.0.0"].features_enabled[_LINUX])
    asserts.true(env, "//:hick-1.0.0" in result.by_fq["rq-1.0.0"].deps[_LINUX])

    # Host world: neither the feature nor the marker nor the edge.
    rq_host = result.by_fq["rq-1.0.0"].host["state"]
    asserts.false(env, "dns" in rq_host["features_enabled"][_LINUX])
    asserts.false(env, "dep:hick" in rq_host["features_enabled"][_LINUX])
    asserts.equals(env, [], sorted(rq_host["deps"][_LINUX]))
    asserts.false(env, _host_active(result, "hick-1.0.0", _LINUX))

    classes = classify_worlds(result.packages, [_LINUX])
    asserts.equals(env, "target_only", classes["hick-1.0.0"])
    asserts.equals(env, "divergent", classes["rq-1.0.0"])
    return unittest.end(env)

def _split_member_build_dep_features_are_amphibious_impl(ctx):
    env = unittest.begin(ctx)

    # cynic shape: the member's build script registers
    # schemas through the BASE codegen instance ([build-dependencies]
    # codegen with "rkyv"), while the proc-macro SPOKE tree pulls codegen's
    # HOST instance without it. Cargo resolves both edges host-side, so both
    # instances agree; member build edges must therefore be
    # feature-AMPHIBIOUS: target-world for activation/labels, but their
    # feature requests reach the host instance too.
    spoke_facts = {
        "codegen-1.0.0": {
            "dependencies": [{"name": "rkyvdep", "optional": True, "default_features": False}],
            "features": {"rkyv": ["dep:rkyvdep"]},
        },
        "rkyvdep-1.0.0": {"dependencies": [], "features": {}},
        "macros-1.0.0": {"dependencies": [{"name": "codegen", "default_features": False}], "features": {}},
    }
    members = [{
        "name": "app",
        "version": "0.1.0",
        "features": {},
        "targets": [{"kind": ["lib"]}],
        "dependencies": [
            {"name": "macros", "kind": None, "features": [], "uses_default_features": False},
            {"name": "codegen", "kind": "build", "features": ["rkyv"], "uses_default_features": False},
        ],
        "lock_dependencies": ["macros", "codegen"],
    }]
    result = _run_workspace_resolution(spoke_facts, members, proc_macro_spokes = ["macros-1.0.0"])

    # The member build edge stays target-world for activation/labels...
    asserts.true(env, _target_active(result, "codegen-1.0.0", _LINUX))
    asserts.true(env, "rkyv" in result.by_fq["codegen-1.0.0"].features_enabled[_LINUX])

    # ...but its "rkyv" request also reaches the host instance (host-activated
    # by the proc-macro tree), so both worlds agree...
    asserts.true(env, _host_active(result, "codegen-1.0.0", _LINUX))
    asserts.true(env, "rkyv" in result.by_fq["codegen-1.0.0"].host["state"]["features_enabled"][_LINUX])
    asserts.equals(env, _target_features(result, "codegen-1.0.0", _LINUX), _host_features(result, "codegen-1.0.0", _LINUX))

    # ...and the feature's transitive closure participates in the host
    # fixpoint: the rkyv-gated optional dep is host-active.
    asserts.true(env, _host_active(result, "rkyvdep-1.0.0", _LINUX))
    asserts.true(env, "//:rkyvdep-1.0.0" in result.by_fq["codegen-1.0.0"].host["state"]["deps"][_LINUX])

    # With both worlds agreeing, codegen is NOT divergent: one base instance
    # serves the member build script and the proc-macro tree consistently.
    classes = classify_worlds(result.packages, [_LINUX])
    asserts.equals(env, "identical", classes["codegen-1.0.0"])
    return unittest.end(env)

def _split_member_build_dep_amphibious_without_host_user_impl(ctx):
    env = unittest.begin(ctx)

    # Without any host-world consumer, the member build edge alone must NOT
    # host-activate the dep: features sit as pending seeds only.
    spoke_facts = {
        "codegen-1.0.0": {
            "dependencies": [{"name": "rkyvdep", "optional": True, "default_features": False}],
            "features": {"rkyv": ["dep:rkyvdep"]},
        },
        "rkyvdep-1.0.0": {"dependencies": [], "features": {}},
    }
    members = [{
        "name": "app",
        "version": "0.1.0",
        "features": {},
        "targets": [{"kind": ["lib"]}],
        "dependencies": [
            {"name": "codegen", "kind": "build", "features": ["rkyv"], "uses_default_features": False},
        ],
        "lock_dependencies": ["codegen"],
    }]
    result = _run_workspace_resolution(spoke_facts, members)

    asserts.true(env, _target_active(result, "codegen-1.0.0", _LINUX))
    asserts.true(env, _target_active(result, "rkyvdep-1.0.0", _LINUX))

    # No host activation, no host state — only pending seeds.
    asserts.equals(env, None, result.by_fq["codegen-1.0.0"].host["state"])
    asserts.true(env, "rkyv" in result.by_fq["codegen-1.0.0"].host["pending_features"][_LINUX])
    asserts.equals(env, None, result.by_fq["rkyvdep-1.0.0"].host["state"])

    classes = classify_worlds(result.packages, [_LINUX])
    asserts.equals(env, "target_only", classes["codegen-1.0.0"])
    asserts.equals(env, "target_only", classes["rkyvdep-1.0.0"])
    return unittest.end(env)

def _split_inactive_triple_renders_legacy_view_impl(ctx):
    env = unittest.begin(ctx)

    # fiemap shape: a crate reachable only behind a cfg(linux)-gated edge is
    # target-active on linux only, but a hand-written `# keep` reference can
    # still CONFIGURE it on darwin. Its rendered view there must stay
    # buildable exactly as unified mode rendered it (deps present), never an
    # empty select branch (silent E0433 compile break).
    triples = [_LINUX, _DARWIN]
    spoke_facts = {
        "fmap-1.0.0": {
            "dependencies": [{"name": "bits", "features": ["std"], "default_features": False}],
            "features": {},
        },
        "bits-1.0.0": {"dependencies": [], "features": {"std": []}},
        # Host-world variant of the same shape: a build tool host-active on
        # linux only via a cfg-gated spoke build-dep.
        "wrapper-1.0.0": {
            "dependencies": [{"name": "tool", "kind": "build", "default_features": False, "target": "cfg(target_os = \"linux\")"}],
            "features": {},
        },
        "tool-1.0.0": {"dependencies": [{"name": "tbits", "default_features": False}], "features": {}},
        "tbits-1.0.0": {"dependencies": [], "features": {}},
    }
    members = [{
        "name": "app",
        "version": "0.1.0",
        "features": {},
        "targets": [{"kind": ["lib"]}],
        "dependencies": [
            {"name": "fmap", "kind": None, "features": ["extra"], "uses_default_features": False, "target": "cfg(target_os = \"linux\")"},
            {"name": "wrapper", "kind": None, "features": [], "uses_default_features": False},
        ],
        "lock_dependencies": ["fmap", "wrapper"],
    }]
    result = _run_workspace_resolution(spoke_facts, members, triples = triples)

    # Activation flags stay chain-accurate at the cfg-gated edges...
    asserts.true(env, _target_active(result, "fmap-1.0.0", _LINUX))
    asserts.false(env, _target_active(result, "fmap-1.0.0", _DARWIN))
    asserts.true(env, _host_active(result, "tool-1.0.0", _LINUX))
    asserts.false(env, _host_active(result, "tool-1.0.0", _DARWIN))

    # ...but an activated item processes ALL cfg-matched triples of its own
    # edges, so the dep buckets carry the unified-equivalent content.
    asserts.true(env, "//:bits-1.0.0" in result.by_fq["fmap-1.0.0"].deps[_DARWIN])
    asserts.true(env, "//:tbits-1.0.0" in result.by_fq["tool-1.0.0"].host["state"]["deps"][_DARWIN])

    classes = classify_worlds(result.packages, triples)
    asserts.equals(env, "target_only", classes["fmap-1.0.0"])
    asserts.equals(env, "host_only", classes["tool-1.0.0"])

    # Rendered base views fall back to the active world's view at inactive
    # triples instead of an empty branch (deps present => still compiles);
    # per-triple feature content keeps unified semantics (the member edge's
    # "extra" was only requested on linux).
    views_fmap = render_world_views(result.by_fq["fmap-1.0.0"], classes["fmap-1.0.0"], classes, triples)
    asserts.equals(env, ["//:bits-1.0.0"], sorted(views_fmap.deps[_DARWIN]))
    asserts.equals(env, ["//:bits-1.0.0"], sorted(views_fmap.deps[_LINUX]))
    asserts.equals(env, ["extra"], sorted(views_fmap.crate_features[_LINUX]))
    asserts.equals(env, [], sorted(views_fmap.crate_features[_DARWIN]))

    views_tool = render_world_views(result.by_fq["tool-1.0.0"], classes["tool-1.0.0"], classes, triples)
    asserts.equals(env, ["//:tbits-1.0.0"], sorted(views_tool.deps[_DARWIN]))
    return unittest.end(env)

def _render_rust_crate_call_world_split_impl(ctx):
    env = unittest.begin(ctx)

    base_attr = dict(
        crate_features = [],
        crate_features_select = {_LINUX: ["heavy"]},
        use_legacy_rules_rust_platforms = False,
        allow_build_script_to_detect_nonhermetic_paths = False,
        build_script_deps = [],
        build_script_deps_select = {_LINUX: ["//:bd-1.0.0_host"]},
        build_script_data = [],
        build_script_data_select = {},
        build_script_env = {},
        build_script_env_select = {},
        build_script_toolchains = [],
        build_script_tools = [],
        build_script_tools_select = {},
        build_script_tags = [],
        rustc_flags = [],
        rustc_flags_select = {},
        crate_tags = [],
        data = [],
        deps = [],
        deps_select = {_LINUX: ["//:r-1.0.0"]},
        aliases = {},
    )
    values = {
        "name": repr("tls"),
        "crate_name": repr(None),
        "purl": repr("pkg:cargo/tls@1.0.0"),
        "version": repr("1.0.0"),
        "binaries": repr({}),
        "build_script": repr("build.rs"),
        "crate_root": repr("src/lib.rs"),
        "edition": repr("2021"),
        "has_lib": repr(True),
        "is_proc_macro": repr(False),
        "links": repr(None),
    }

    # Without host attrs the rendered call carries no world-split params.
    rendered = render_rust_crate_call(struct(**base_attr), values)
    asserts.false(env, "host_" in rendered)
    asserts.false(env, "unactivated" in rendered)
    asserts.false(env, "build_script_aliases" in rendered)

    # A divergent crate's call renders the host views.
    rendered = render_rust_crate_call(
        struct(
            build_script_aliases = {"//:bd-1.0.0_host": "bd"},
            host_deps_select = {_LINUX: ["//:r-1.0.0_host"]},
            host_crate_features_select = {_LINUX: ["dep:r", "light"]},
            host_build_script_deps_select = {_LINUX: ["//:bd-1.0.0_host"]},
            host_aliases = {"//:r-1.0.0_host": "r_alias"},
            **base_attr
        ),
        values,
    )
    asserts.true(env, 'host_crate_features = ["light"]' in rendered)
    asserts.true(env, "host_conditional_crate_features = {}" in rendered)
    asserts.true(env, '"//:r-1.0.0_host"' in rendered)
    asserts.true(env, '"//:r-1.0.0_host": "r_alias"' in rendered)
    asserts.true(env, "build_script_aliases = {" in rendered)
    asserts.true(env, '"//:bd-1.0.0_host": "bd"' in rendered)
    asserts.false(env, "unactivated" in rendered)

    # An unactivated crate's call renders the stub marker.
    rendered = render_rust_crate_call(struct(unactivated = True, **base_attr), values)
    asserts.true(env, "unactivated = True" in rendered)
    return unittest.end(env)

render_world_views_divergence_test = unittest.make(_render_world_views_divergence_impl)
render_world_views_target_only_build_dep_rewrite_test = unittest.make(_render_world_views_target_only_build_dep_rewrite_impl)
render_world_views_disjoint_triple_merge_test = unittest.make(_render_world_views_disjoint_triple_merge_impl)
render_world_views_unactivated_test = unittest.make(_render_world_views_unactivated_impl)
workspace_dep_data_member_world_boundary_test = unittest.make(_workspace_dep_data_member_world_boundary_impl)
split_host_deps_view_completeness_test = unittest.make(_split_host_deps_view_completeness_impl)
split_optional_dep_target_enablement_does_not_cross_test = unittest.make(_split_optional_dep_target_enablement_does_not_cross_impl)
split_member_build_dep_features_are_amphibious_test = unittest.make(_split_member_build_dep_features_are_amphibious_impl)
split_member_build_dep_amphibious_without_host_user_test = unittest.make(_split_member_build_dep_amphibious_without_host_user_impl)
split_inactive_triple_renders_legacy_view_test = unittest.make(_split_inactive_triple_renders_legacy_view_impl)
render_rust_crate_call_world_split_test = unittest.make(_render_rust_crate_call_world_split_impl)

split_sqlx_shape_test = unittest.make(_split_sqlx_shape_impl)
split_build_dep_crossing_and_stickiness_test = unittest.make(_split_build_dep_crossing_and_stickiness_impl)
split_member_proc_macro_is_world_boundary_test = unittest.make(_split_member_proc_macro_is_world_boundary_impl)
split_multi_kind_dep_feature_forwarding_test = unittest.make(_split_multi_kind_dep_feature_forwarding_impl)
split_optional_weak_features_per_world_test = unittest.make(_split_optional_weak_features_per_world_impl)
split_disjoint_triple_activity_test = unittest.make(_split_disjoint_triple_activity_impl)
split_deep_chain_converges_test = unittest.make(_split_deep_chain_converges_impl)
split_build_dep_chain_activation_drain_test = unittest.make(_split_build_dep_chain_activation_drain_impl)
split_annotations_seed_without_activation_test = unittest.make(_split_annotations_seed_without_activation_impl)
split_transitive_label_divergence_test = unittest.make(_split_transitive_label_divergence_impl)
proc_macro_bit_plumbing_test = unittest.make(_proc_macro_bit_plumbing_impl)

def cargo_workspace_graph_tests():
    return unittest.suite(
        "cargo_workspace_graph_tests",
        cargo_toml_dependencies_handles_workspace_inheritance_test,
        cargo_toml_dependencies_normalizes_dependency_specs_test,
        proc_macro_bit_plumbing_test,
        render_rust_crate_call_world_split_test,
        render_world_views_disjoint_triple_merge_test,
        render_world_views_divergence_test,
        render_world_views_target_only_build_dep_rewrite_test,
        render_world_views_unactivated_test,
        resolve_package_facts_attaches_feature_resolutions_test,
        select_package_fq_dep_uses_package_name_test,
        select_package_fq_dep_uses_req_for_duplicate_versions_test,
        split_annotations_seed_without_activation_test,
        split_build_dep_chain_activation_drain_test,
        split_build_dep_crossing_and_stickiness_test,
        split_deep_chain_converges_test,
        split_disjoint_triple_activity_test,
        split_host_deps_view_completeness_test,
        split_inactive_triple_renders_legacy_view_test,
        split_lockfile_packages_finds_local_package_paths_test,
        split_member_build_dep_amphibious_without_host_user_test,
        split_member_build_dep_features_are_amphibious_test,
        split_member_proc_macro_is_world_boundary_test,
        split_multi_kind_dep_feature_forwarding_test,
        split_optional_dep_target_enablement_does_not_cross_test,
        split_optional_weak_features_per_world_test,
        split_sqlx_shape_test,
        split_transitive_label_divergence_test,
        workspace_dep_data_member_world_boundary_test,
    )
