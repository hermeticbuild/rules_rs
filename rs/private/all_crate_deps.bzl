load(":cargo_select.bzl", "cargo_select")
load(":select_utils.bzl", "compute_select", "platform_label")

def _configured_deps(dep_data, normal, normal_dev, build, filter_prefix, use_legacy_rules_rust_platforms):
    values = {}
    for context, definition in dep_data["configurations"].items():
        build_deps = None
        if build:
            if not context:
                for triple, build_context in definition["build_contexts"].items():
                    if build_context != context:
                        for deps in definition["build_deps_by_target"].get(triple, {}).values():
                            if deps:
                                fail("Build dependencies require a different Cargo resolution. Use cargo_build_script from the generated Cargo repository's defs.bzl.")
            for deps_by_platform in definition["build_deps_by_target"].values():
                if build_deps == None:
                    build_deps = deps_by_platform
                elif build_deps != deps_by_platform:
                    fail("Build-script dependencies differ by target triple. Use cargo_build_script from the generated Cargo repository's defs.bzl.")
        build_deps = build_deps or {}
        triples = set(definition["crate_features_select"] if normal or normal_dev or not build_deps else [])
        triples.update(build_deps)
        by_triple = {}
        for triple in triples:
            deps = set(definition["deps_select"].get(triple, []) if normal else [])
            if normal_dev:
                deps.update(dep_data.get("dev_deps", []))
                platform = platform_label(triple, use_legacy_rules_rust_platforms)
                deps.update(dep_data.get("dev_deps_by_platform", {}).get(platform, []))
            deps.update(build_deps.get(triple, []))
            by_triple[triple] = sorted([dep for dep in deps if not filter_prefix or dep.startswith(filter_prefix)])
        values[context] = by_triple
    return values

def _build_aliases_by_platform(definition):
    first = None
    for owner, deps_by_platform in definition["build_deps_by_target"].items():
        aliases = definition["build_aliases_by_target"].get(owner, {})
        selected = {
            triple: {dep: aliases[dep] for dep in deps if dep in aliases}
            for triple, deps in deps_by_platform.items()
        }
        if first == None:
            first = selected
        elif first != selected:
            fail("Build-script aliases differ by target triple. Use cargo_build_script from the generated Cargo repository's defs.bzl.")
    return first or {}

def crate_features(dep_data, hub_name = None, use_legacy_rules_rust_platforms = False):
    """Return the features selected for this Cargo package."""
    if "configurations" in dep_data:
        return cargo_select({
            context: definition["crate_features_select"]
            for context, definition in dep_data["configurations"].items()
        }, hub_name, use_legacy_rules_rust_platforms)
    features = dep_data.get("crate_features", [])
    branches = dep_data.get("crate_features_by_platform", {})
    return features + select(branches | {"//conditions:default": []}) if branches else features

def crate_aliases(dep_data, normal = False, normal_dev = False, build = False, hub_name = None, use_legacy_rules_rust_platforms = False):
    """Returns aliases for selected dependency kinds, or all kinds by default."""
    if "configurations" in dep_data:
        if not normal and not normal_dev and not build:
            normal, normal_dev, build = True, True, True
        values = _configured_deps(dep_data, normal, normal_dev, False, None, use_legacy_rules_rust_platforms)
        for context, by_triple in values.items():
            definition = dep_data["configurations"][context]
            aliases = dict(definition["aliases"]) if normal else {}
            if normal_dev:
                aliases.update(dep_data.get("dev_aliases", {}))
            for triple, deps in by_triple.items():
                by_triple[triple] = {dep: aliases[dep] for dep in deps if dep in aliases}
            if build:
                for triple, build_aliases in _build_aliases_by_platform(definition).items():
                    by_triple[triple] = by_triple.get(triple, {}) | build_aliases
        return cargo_select(values, hub_name, use_legacy_rules_rust_platforms)
    if not normal and not normal_dev and not build:
        return dep_data["aliases"]

    aliases = {}
    if normal:
        aliases.update(dep_data.get("normal_aliases", {}))
    if normal_dev:
        aliases.update(dep_data.get("dev_aliases", {}))
    if build:
        aliases.update(dep_data.get("build_aliases", {}))
    return aliases

def merge_structured_dep_specs(specs, platforms, filter_prefix):
    merged_by_platform = {platform: set() for platform in platforms}
    merged_deps = set()

    for shared_items, per_platform_items in specs:
        for dep in shared_items:
            if not filter_prefix or dep.startswith(filter_prefix):
                merged_deps.add(dep)

        for platform, deps in per_platform_items.items():
            if filter_prefix:
                deps = [dep for dep in deps if dep.startswith(filter_prefix)]
            merged_by_platform[platform].update(deps)

    deps, per_platform = compute_select(merged_deps, merged_by_platform)
    return sorted(deps), per_platform

def all_crate_deps(
        dep_data,
        platforms,
        normal = False,
        normal_dev = False,
        build = False,
        filter_prefix = None,
        hub_name = None,
        use_legacy_rules_rust_platforms = False):
    if "configurations" in dep_data:
        return cargo_select(_configured_deps(
            dep_data,
            normal or not (normal_dev or build),
            normal_dev,
            build,
            filter_prefix,
            use_legacy_rules_rust_platforms,
        ), hub_name, use_legacy_rules_rust_platforms)
    specs = []

    if normal_dev:
        specs.append((dep_data.get("dev_deps", []), dep_data.get("dev_deps_by_platform", {})))

    if build:
        specs.append((dep_data.get("build_deps", []), dep_data.get("build_deps_by_platform", {})))

    if normal or not specs:
        specs.append((dep_data.get("deps", []), dep_data.get("deps_by_platform", {})))

    deps, per_platform = merge_structured_dep_specs(
        specs,
        platforms,
        filter_prefix,
    )
    if not per_platform:
        return deps

    branches = {platform: deps for platform, deps in sorted(per_platform.items())}
    branches["//conditions:default"] = []
    return deps + select(branches)
