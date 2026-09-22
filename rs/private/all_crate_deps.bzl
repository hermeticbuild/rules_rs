load(":cargo_select.bzl", "cargo_select")
load(":select_utils.bzl", "platform_label")

def _build_aliases_by_platform(definition):
    first = None
    rows = definition["build_deps_by_target"]
    for owner in definition["crate_features_select"]:
        deps_by_platform = rows.get(owner, rows.get("", {}))
        selected = {
            triple: {dep: alias for dep, alias in deps.items() if alias != None}
            for triple, deps in deps_by_platform.items()
        }
        if first == None:
            first = selected
        elif first != selected:
            fail("Build-script aliases differ by target triple. Use cargo_build_script from the generated Cargo repository's defs.bzl.")
    return first or {}

def crate_features(dep_data, hub_name = None, use_legacy_rules_rust_platforms = False):
    """Return the features selected for this Cargo package."""
    return cargo_select({
        context: definition["crate_features_select"]
        for context, definition in dep_data["configurations"].items()
    }, hub_name, use_legacy_rules_rust_platforms)

def crate_aliases(dep_data, normal = False, normal_dev = False, build = False, hub_name = None, use_legacy_rules_rust_platforms = False):
    """Return aliases for selected dependency kinds, defaulting to normal."""
    normal = normal or not (normal_dev or build)
    values = {}
    for context, definition in dep_data["configurations"].items():
        by_triple = {}
        for triple in definition["crate_features_select"]:
            aliases = definition["deps_select"].get(triple, {}) if normal else {}
            if normal_dev:
                platform = platform_label(triple, use_legacy_rules_rust_platforms)
                dev_deps = dep_data["dev_deps"] | dep_data["dev_deps_by_platform"].get(platform, {})
                aliases = aliases | {dep: alias for dep, alias in dev_deps.items() if alias != None}
            by_triple[triple] = {dep: aliases[dep] for dep in sorted(aliases) if aliases[dep] != None}
        if build:
            for triple, build_aliases in _build_aliases_by_platform(definition).items():
                by_triple[triple] = by_triple.get(triple, {}) | build_aliases
        values[context] = by_triple
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
    for context, definition in dep_data["configurations"].items():
        build_deps = None
        rows = definition["build_deps_by_target"]
        if build:
            if not context:
                for triple in definition["build_contexts"]:
                    for deps in rows.get(triple, rows.get("", {})).values():
                        if deps:
                            fail("Build dependencies require a different Cargo resolution. Use cargo_build_script from the generated Cargo repository's defs.bzl.")
            for triple in definition["crate_features_select"]:
                deps_by_platform = {platform: sorted(deps) for platform, deps in rows.get(triple, rows.get("", {})).items()}
                if build_deps == None:
                    build_deps = deps_by_platform
                elif build_deps != deps_by_platform:
                    fail("Build-script dependencies differ by target triple. Use cargo_build_script from the generated Cargo repository's defs.bzl.")
        build_deps = build_deps or {}
        triples = set(definition["crate_features_select"] if normal or normal_dev or not build_deps else [])
        triples.update(build_deps)
        by_triple = {}
        for triple in triples:
            deps = set(definition["deps_select"].get(triple, {}) if normal else [])
            if normal_dev:
                deps.update(dep_data["dev_deps"])
                platform = platform_label(triple, use_legacy_rules_rust_platforms)
                deps.update(dep_data["dev_deps_by_platform"].get(platform, {}))
            deps.update(build_deps.get(triple, []))
            by_triple[triple] = sorted([dep for dep in deps if not filter_prefix or dep.startswith(filter_prefix)])
        values[context] = by_triple
    return cargo_select(values, hub_name, use_legacy_rules_rust_platforms)
