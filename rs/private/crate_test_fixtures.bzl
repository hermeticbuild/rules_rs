"""Crate test fixtures."""

load("@bazel_skylib//lib:unittest.bzl", "analysistest", "asserts")
load("//rs/private:crate_compatibility.bzl", "compilation_fingerprint")

REGISTRY = "sparse+https://index.crates.io/"

_REGISTRY = REGISTRY

OTHER_REGISTRY = "sparse+https://registry.example.com/index/"

_OTHER_REGISTRY = OTHER_REGISTRY

GIT = "git+https://example.com/workspace.git?rev=main#0123456789abcdef"

_GIT = GIT

def coalescer():
    return {
        "assignments": {},
        "identities_by_repo": {},
        "packages": {},
    }

_coalescer = coalescer

def package(name = "shared", version = "1.2.3", checksum = "abc", source = _REGISTRY, **kwargs):
    return {
        "checksum": checksum,
        "name": name,
        "source": source,
        "version": version,
    } | kwargs

_package = package

def annotation(
        additive_build_file = None,
        additive_build_file_content = "",
        gen_binaries = [],
        patch_args = [],
        patch_tool = None,
        patches = [],
        workspace_cargo_toml = "Cargo.toml"):
    return struct(
        additive_build_file = additive_build_file,
        additive_build_file_content = additive_build_file_content,
        gen_binaries = gen_binaries,
        patch_args = patch_args,
        patch_tool = patch_tool,
        patches = patches,
        workspace_cargo_toml = workspace_cargo_toml,
    )

_annotation = annotation

def fingerprint(
        features = [],
        features_select = {},
        gen_binaries = [],
        deps = [],
        deps_select = {},
        build_deps = [],
        build_deps_select = {},
        aliases = {},
        weak = False,
        weak_requests = [],
        feature_sensitive = False,
        platforms = ["x86_64-unknown-linux-gnu"],
        patches = [],
        patch_args = [],
        patch_tool = "",
        additive_build_file_content = "",
        source = _REGISTRY,
        strip_prefix = None,
        build_script_env_files = [],
        link_deps = [],
        action = {}):
    kwargs = {
        "aliases": aliases,
        "allow_build_script_to_detect_nonhermetic_paths": False,
        "build_script_data": [],
        "build_script_data_select": {},
        "build_script_deps": build_deps,
        "build_script_deps_select": build_deps_select,
        "build_script_env": {},
        "build_script_env_files": build_script_env_files,
        "build_script_env_select": {},
        "build_script_tags": [],
        "build_script_toolchains": [],
        "build_script_tools": [],
        "build_script_tools_select": {},
        "crate_features": features,
        "crate_features_select": features_select,
        "crate_tags": [],
        "data": [],
        "deps": deps,
        "deps_select": deps_select,
        "gen_build_script": "auto",
        "hub_name": "{hub}",
        "link_deps": link_deps,
        "platform_triples": platforms,
        "rustc_env": {},
        "rustc_flags": [],
        "rustc_flags_select": {},
        "use_legacy_rules_rust_platforms": False,
    }
    kwargs.update(action)
    package = _package(
        source = source,
        has_feature_sensitive_target_dependencies = feature_sensitive,
        has_weak_dependency_features = weak,
        strip_prefix = strip_prefix,
        weak_dependency_feature_requests = weak_requests,
    )
    annotation = _annotation(
        additive_build_file_content = additive_build_file_content,
        gen_binaries = gen_binaries,
        patch_args = patch_args,
        patch_tool = patch_tool or None,
        patches = patches,
    )
    return compilation_fingerprint(package, annotation, kwargs, platforms)

_fingerprint = fingerprint

def fq(package):
    return "%s-%s" % (package["name"], package["version"])

_fq = fq

def numbered_name(prefix, number, width):
    return prefix + ("00000" + str(number))[-width:]

_numbered_name = numbered_name

def resolution(deps = {}, build_deps = {}):
    return struct(deps = deps, build_deps = build_deps)

_resolution = resolution

def assert_dependency_order(env, ordered, resolutions, hub_name):
    positions = {_fq(package): i for i, package in enumerate(ordered)}
    asserts.equals(env, len(ordered), len(positions))
    for package in ordered:
        dependent = _fq(package)
        resolution = resolutions[dependent]
        for deps_by_triple in [resolution.deps, resolution.build_deps]:
            for labels in deps_by_triple.values():
                for label in labels:
                    prefix = "@%s//:" % hub_name
                    if label.startswith(prefix):
                        dependency = label.removeprefix(prefix)
                        if dependency in positions:
                            asserts.true(
                                env,
                                positions[dependency] < positions[dependent],
                                "%s must precede %s" % (dependency, dependent),
                            )

_assert_dependency_order = assert_dependency_order

def chain_graph(size, hub_name = "hub"):
    packages = []
    resolutions = {}
    for i in range(size):
        name = _numbered_name("node-", i, 5)
        package = _package(name = name, version = "1.0.0")
        packages.append(package)
        deps = {}
        if i:
            deps = {"linux": ["@%s//:%s-1.0.0" % (hub_name, _numbered_name("node-", i - 1, 5))]}
        resolutions[_fq(package)] = _resolution(deps = deps)
    return packages, resolutions

_chain_graph = chain_graph

def crate_kwargs(fingerprint):
    return fingerprint["exact"]["crate_rule"] | fingerprint["union"] | fingerprint["hub_local"]

_crate_kwargs = crate_kwargs

def repository_kwargs(fingerprint):
    kwargs = _crate_kwargs(fingerprint)
    kwargs.pop("gen_binaries")
    return kwargs

_repository_kwargs = repository_kwargs

def active_targets(fingerprint, direct_key, select_key):
    kwargs = _crate_kwargs(fingerprint)
    targets = {str(label): True for label in kwargs[direct_key]}
    for labels in kwargs[select_key].values():
        for label in labels:
            targets[str(label)] = True
    return targets

_active_targets = active_targets

def extern_name(target, aliases):
    return aliases.get(target, target.rsplit(":", 1)[-1].replace("-", "_"))

_extern_name = extern_name

def assert_valid_merged_action(env, merged, direct_key, select_key):
    kwargs = _crate_kwargs(merged)
    aliases = kwargs["aliases"]
    for selected in kwargs[select_key].values():
        targets_by_extern = {}
        for target in kwargs[direct_key] + selected:
            target = str(target)
            extern_name = _extern_name(target, aliases)
            asserts.false(env, extern_name in targets_by_extern and targets_by_extern[extern_name] != target)
            targets_by_extern[extern_name] = target

_assert_valid_merged_action = assert_valid_merged_action

def expect_failure(expected):
    def _impl(ctx):
        env = analysistest.begin(ctx)
        asserts.expect_failure(env, expected)
        return analysistest.end(env)

    return analysistest.make(_impl, expect_failure = True)

_expect_failure = expect_failure
