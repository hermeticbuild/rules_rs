load(":cargo_select.bzl", "cargo_select")
load(":select_utils.bzl", "platform_label")

def _build_aliases_by_triple(configuration):
    first = None
    for deps_by_exec_triple in configuration["build_deps_by_triple"].values():
        selected = {
            exec_platform_triple: {dep: alias for dep, alias in deps.items() if alias != None}
            for exec_platform_triple, deps in deps_by_exec_triple.items()
        }
        if first == None:
            first = selected
        elif first != selected:
            fail("Build-script aliases differ by target triple. Use cargo_build_script from the generated Cargo repository's defs.bzl.")
    return first or {}

def crate_features(dep_data, hub_name = None, use_legacy_rules_rust_platforms = False):
    """Return the features selected for this Cargo package."""
    return cargo_select({
        cargo_target_triple: configuration["crate_features_by_triple"]
        for cargo_target_triple, configuration in dep_data["configurations"].items()
    }, hub_name, use_legacy_rules_rust_platforms)

def crate_aliases(dep_data, normal = False, normal_dev = False, build = False, hub_name = None, use_legacy_rules_rust_platforms = False):
    """Return aliases for selected dependency kinds, defaulting to normal."""
    normal = normal or not (normal_dev or build)
    values = {}
    for cargo_target_triple, configuration in dep_data["configurations"].items():
        build_aliases = _build_aliases_by_triple(configuration) if build else {}
        platform_triples = set(configuration["crate_features_by_triple"])
        platform_triples.update(build_aliases)
        by_triple = {}
        for platform_triple in platform_triples:
            aliases = configuration["deps_by_triple"].get(platform_triple, {}) if normal else {}
            if normal_dev:
                platform = platform_label(platform_triple, use_legacy_rules_rust_platforms)
                dev_deps = dep_data["dev_deps"] | dep_data["dev_deps_by_platform"].get(platform, {})
                aliases = aliases | {dep: alias for dep, alias in dev_deps.items() if alias != None}
            by_triple[platform_triple] = {dep: aliases[dep] for dep in sorted(aliases) if aliases[dep] != None}
            by_triple[platform_triple].update(build_aliases.get(platform_triple, {}))
        values[cargo_target_triple] = by_triple
    return cargo_select(values, hub_name, use_legacy_rules_rust_platforms)

def all_crate_deps(
        dep_data,
        normal = False,
        normal_dev = False,
        build = False,
        filter_prefix = None,
        hub_name = None,
        use_legacy_rules_rust_platforms = False):
    normal = normal or not (normal_dev or build)
    values = {}
    for cargo_target_triple, configuration in dep_data["configurations"].items():
        build_deps = None
        if build:
            if not cargo_target_triple and configuration["build_cargo_target_triple_required_on"]:
                fail("Build dependencies require a different Cargo resolution. Use cargo_build_script from the generated Cargo repository's defs.bzl.")
            for deps_by_exec_triple in configuration["build_deps_by_triple"].values():
                selected = {exec_platform_triple: set(deps) for exec_platform_triple, deps in deps_by_exec_triple.items()}
                if build_deps == None:
                    build_deps = selected
                elif build_deps != selected:
                    fail("Build-script dependencies differ by target triple. Use cargo_build_script from the generated Cargo repository's defs.bzl.")
        build_deps = build_deps or {}
        platform_triples = set(configuration["crate_features_by_triple"] if normal or normal_dev or not build_deps else [])
        platform_triples.update(build_deps)
        by_triple = {}
        for platform_triple in platform_triples:
            deps = set(configuration["deps_by_triple"].get(platform_triple, {}) if normal else [])
            if normal_dev:
                deps.update(dep_data["dev_deps"])
                platform = platform_label(platform_triple, use_legacy_rules_rust_platforms)
                deps.update(dep_data["dev_deps_by_platform"].get(platform, {}))
            deps.update(build_deps.get(platform_triple, []))
            by_triple[platform_triple] = sorted([dep for dep in deps if dep.startswith(filter_prefix)] if filter_prefix else deps)
        values[cargo_target_triple] = by_triple
    return cargo_select(values, hub_name, use_legacy_rules_rust_platforms)
