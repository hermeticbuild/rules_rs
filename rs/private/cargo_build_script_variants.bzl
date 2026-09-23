"""Select build-script features and dependencies before the exec transition."""

# buildifier: disable=bzl-visibility
load("@rules_rust//cargo/private:cargo_build_script.bzl", "name_to_crate_name", "name_to_pkg_name")
load("//rs:cargo_build_script.bzl", "cargo_build_script")
load(":cargo_select.bzl", "cargo_select")
load(":select_utils.bzl", "platform_label", "shared_and_per_platform")

def cargo_build_script_for_configurations(
        name,
        configurations,
        hub_name,
        preserve_cargo_target_triple = False,
        crate_features = [],
        deps = [],
        aliases = {},
        use_legacy_rules_rust_platforms = False,
        **kwargs):
    """Select a build script before the exec transition and return its dependency list."""
    scripts = {}
    for cargo_target_triple, configuration in configurations.items():
        build_deps_by_triple = configuration["build_deps_by_triple"]
        common_deps = shared_and_per_platform(build_deps_by_triple.get("", {}), use_legacy_rules_rust_platforms)
        platform_triples = sorted(configuration["crate_features_by_triple"])
        if use_legacy_rules_rust_platforms:
            platform_triples = sorted({platform_label(triple, True): triple for triple in platform_triples}.values())
        for platform_triple in platform_triples:
            script_deps, deps_by_platform = shared_and_per_platform(
                build_deps_by_triple[platform_triple],
                use_legacy_rules_rust_platforms,
            ) if platform_triple in build_deps_by_triple else common_deps
            recipe = {
                "crate_features": configuration["crate_features_by_triple"][platform_triple],
                "deps": script_deps,
                "deps_by_platform": deps_by_platform,
                "cargo_target_triple": (cargo_target_triple or platform_triple) if preserve_cargo_target_triple or platform_triple in configuration["build_cargo_target_triple_required_on"] else "",
            }
            key = json.encode(recipe)
            if key not in scripts:
                recipe["conditions"] = {}
                recipe["script_suffix"] = cargo_target_triple + "_" + platform_triple if cargo_target_triple else platform_triple
                scripts[key] = recipe
            scripts[key]["conditions"].setdefault(cargo_target_triple, []).append(platform_triple)

    split = len(scripts) > 1
    script_kwargs = dict(kwargs) if split else kwargs
    if split:
        branches = {}

        # Preserve the environment derived by rules_rust from the original name.
        if kwargs.get("pkg_name") == None:
            script_kwargs["pkg_name"] = name_to_pkg_name(name)
        rustc_env = dict(kwargs.get("rustc_env", {}))
        rustc_env.setdefault("CARGO_CRATE_NAME", name_to_crate_name(name_to_pkg_name(name)))
        script_kwargs["rustc_env"] = rustc_env
        tags = kwargs.get("tags") or []
        if "manual" not in tags:
            script_kwargs["tags"] = tags + ["manual"]

    for variant in scripts.values():
        script_name = name
        if split:
            script_suffix = variant["script_suffix"]
            script_name = name + "_" + script_suffix
            for cargo_target_triple, platform_triples in variant["conditions"].items():
                by_triple = branches.setdefault(cargo_target_triple, {})
                for platform_triple in platform_triples:
                    by_triple[platform_triple] = ":" + script_name

            # Distinct build.rs configurations need distinct metadata when their
            # binaries share an exec configuration.
            # https://github.com/hermeticbuild/rules_rs/issues/161
            script_kwargs["rustc_flags"] = kwargs.get("rustc_flags", []) + [
                "--codegen=metadata=-" + script_suffix,
            ]
        if hub_name:
            script_kwargs["cargo_target_triple_map"] = {cargo_target_triple: variant["cargo_target_triple"] for cargo_target_triple in variant["conditions"] if cargo_target_triple != variant["cargo_target_triple"]}
        script_deps = list(variant["deps"])
        script_aliases = {dep: alias for dep, alias in variant["deps"].items() if alias}
        script_aliases.update(aliases)
        if variant["deps_by_platform"]:
            script_aliases = select({
                platform: script_aliases | {dep: alias for dep, alias in items.items() if alias and dep not in aliases}
                for platform, items in variant["deps_by_platform"].items()
            } | {"//conditions:default": script_aliases})
            script_deps = script_deps + select({
                platform: list(items)
                for platform, items in variant["deps_by_platform"].items()
            } | {"//conditions:default": []})
        cargo_build_script(
            name = script_name,
            crate_features = crate_features + variant["crate_features"],
            deps = deps + script_deps if deps else script_deps,
            aliases = script_aliases,
            **script_kwargs
        )
    if split:
        # The alias selects before cargo_build_script.script applies cfg=exec.
        native.alias(
            name = name,
            actual = cargo_select(branches, hub_name, use_legacy_rules_rust_platforms),
            **{key: kwargs[key] for key in ["tags", "testonly", "visibility", "target_compatible_with"] if key in kwargs}
        )
    return [name] if scripts else []
