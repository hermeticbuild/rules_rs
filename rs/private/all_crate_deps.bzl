load(":select_utils.bzl", "compute_select")

def crate_aliases(dep_data, normal = False, normal_dev = False, build = False):
    """Returns aliases for selected dependency kinds, or all kinds by default."""
    if not normal and not normal_dev and not build:
        return dep_data["aliases"]

    aliases = {}
    if normal:
        aliases.update(dep_data.get("normal_aliases", {}))
    if normal_dev:
        aliases.update(dep_data.get("dev_aliases", {}))
    if build:
        if "build_scripts" in dep_data:
            scripts = dep_data["build_scripts"]
            build_aliases = scripts[0]["aliases"]
            for script in scripts:
                if script["aliases"] != build_aliases:
                    fail("Build-script aliases differ by target triple. Use cargo_build_script from the generated Cargo repository's defs.bzl.")
            aliases.update(build_aliases)
        else:
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
        build_platforms = []):
    specs = []

    if normal_dev:
        specs.append((dep_data.get("dev_deps", []), dep_data.get("dev_deps_by_platform", {})))

    if build:
        if "build_scripts" in dep_data:
            scripts = dep_data["build_scripts"]
            build_deps = scripts[0]
            for script in scripts:
                if script["deps"] != build_deps["deps"] or script["deps_by_platform"] != build_deps["deps_by_platform"]:
                    fail("Build-script dependencies differ by target triple. Use cargo_build_script from the generated Cargo repository's defs.bzl.")
            specs.append(([], {
                platform: build_deps["deps"] + build_deps["deps_by_platform"].get(platform, [])
                for platform in build_platforms
            }))
            platforms = set(platforms if normal or normal_dev else [])
            platforms.update(build_platforms)
        else:
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
