load(":select_utils.bzl", "compute_select")

def _build_profile_field(dep_data, field, target_triple):
    profiles = dep_data["build_script_profiles"]
    if target_triple != None:
        if target_triple not in profiles:
            fail("Unknown target_triple %r; expected one of %s" % (target_triple, sorted(profiles)))
        return profiles[target_triple][field]

    values = [profile[field] for profile in profiles.values()]
    value = values[0] if values else {}
    if any([candidate != value for candidate in values[1:]]):
        description = "dependencies" if field == "deps" else "aliases"
        fail("Build-script %s differ by target triple. Use cargo_build_script from the generated Cargo repository's defs.bzl, or pass target_triple explicitly." % description)
    return value

def crate_aliases(dep_data, normal = False, normal_dev = False, build = False, target_triple = None):
    """Returns aliases for selected dependency kinds, or all kinds by default."""
    if not normal and not normal_dev and not build:
        return dep_data["aliases"]

    aliases = {}
    if normal:
        aliases.update(dep_data.get("normal_aliases", {}))
    if normal_dev:
        aliases.update(dep_data.get("dev_aliases", {}))
    if build:
        if "build_script_profiles" in dep_data:
            aliases.update(_build_profile_field(dep_data, "aliases", target_triple))
        else:
            aliases.update(dep_data.get("build_aliases", {}))
    return aliases

def _filter_by_prefix(deps, prefix):
    return [dep for dep in deps if dep.startswith(prefix)]

def _kind_dep_spec(dep_data, kind):
    return (
        dep_data.get(kind, []),
        dep_data.get(kind + "_by_platform", {}),
    )

def merge_structured_dep_specs(specs, platforms, filter_prefix):
    merged_by_platform = {}
    merged_deps = set()

    for platform in platforms:
        merged_by_platform[platform] = set()

    for shared_items, per_platform_items in specs:
        for dep in shared_items:
            if not filter_prefix or dep.startswith(filter_prefix):
                merged_deps.add(dep)

        for platform, deps in per_platform_items.items():
            filtered = _filter_by_prefix(deps, filter_prefix) if filter_prefix else deps
            if not filtered:
                continue

            existing = merged_by_platform.get(platform)
            if existing == None:
                merged_by_platform[platform] = set(filtered)
                continue

            existing.update(filtered)

    deps, per_platform = compute_select(merged_deps, merged_by_platform)
    return sorted(deps), per_platform

def all_crate_deps(
        dep_data,
        platforms,
        normal = False,
        normal_dev = False,
        build = False,
        filter_prefix = None,
        target_triple = None):
    specs = []

    if normal_dev:
        specs.append(_kind_dep_spec(dep_data, "dev_deps"))

    if build:
        if "build_script_profiles" in dep_data:
            execution_platforms = dep_data["build_script_platforms"]
            execution_deps = _build_profile_field(dep_data, "deps", target_triple)
            by_platform = {}
            for triple, deps in execution_deps.items():
                by_platform.setdefault(execution_platforms[triple], []).extend(deps)
            specs.append(([], by_platform))
            selected_platforms = set(platforms if normal or normal_dev else [])
            selected_platforms.update(execution_platforms.values())
            platforms = sorted(selected_platforms)
        else:
            specs.append(_kind_dep_spec(dep_data, "build_deps"))

    if normal or not specs:
        specs.append(_kind_dep_spec(dep_data, "deps"))

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
