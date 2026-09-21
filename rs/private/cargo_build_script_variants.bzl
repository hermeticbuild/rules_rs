"""Select build-script features and dependencies before the exec transition."""

# buildifier: disable=bzl-visibility
load("@rules_rust//cargo/private:cargo_build_script.bzl", "name_to_crate_name", "name_to_pkg_name")
load("//rs:cargo_build_script.bzl", "cargo_build_script")
load(":select_utils.bzl", "platform_label", "shared_and_per_platform")

def build_script_variants(
        crate_features_select,
        build_deps_by_target,
        build_aliases_by_target,
        use_legacy_rules_rust_platforms,
        crate_features = []):
    """Group target triples with equal build-script features, deps, and aliases.

    Args:
        crate_features_select: Features keyed by every original target triple.
        build_deps_by_target: Execution-platform dependencies keyed by original target triple.
        build_aliases_by_target: Aliases keyed by original target triple.
        use_legacy_rules_rust_platforms: Whether to use rules_rust platform labels.
        crate_features: Features shared by every target triple.

    Returns:
        Dictionaries containing target_triples, crate_features, deps,
        deps_by_platform, and aliases. Each dictionary describes one build script.
    """
    if not crate_features_select:
        crate_features_select = {"": []}
    variants = {}
    for triple in sorted(crate_features_select):
        features = set(crate_features_select[triple])
        features.update(crate_features)
        deps, deps_by_platform = shared_and_per_platform(build_deps_by_target.get(triple, {}), use_legacy_rules_rust_platforms)
        recipe = {
            "crate_features": sorted(features),
            "deps": deps,
            "deps_by_platform": deps_by_platform,
            "aliases": build_aliases_by_target.get(triple, {}),
        }
        key = json.encode(recipe)
        if key not in variants:
            recipe["target_triples"] = []
            variants[key] = recipe
        variants[key]["target_triples"].append(triple)
    return variants.values()

def cargo_build_script_for_targets(
        name,
        build_scripts,
        crate_features = [],
        deps = [],
        aliases = {},
        use_legacy_rules_rust_platforms = False,
        **kwargs):
    """Declare build scripts selected in the original target configuration.

    Args:
        name: Build-script target name.
        build_scripts: Build-script definitions returned by build_script_variants.
        crate_features: Features shared by every target triple.
        deps: Additional dependencies shared by every target triple.
        aliases: Additional dependency aliases shared by every target triple.
        use_legacy_rules_rust_platforms: Whether to use rules_rust platform labels.
        **kwargs: Remaining cargo_build_script arguments.
    """

    split = len(build_scripts) > 1
    if split:
        branches = {}

        # Preserve the environment derived by rules_rust from the original name.
        if kwargs.get("pkg_name") == None:
            kwargs["pkg_name"] = name_to_pkg_name(name)
        rustc_env = dict(kwargs.get("rustc_env", {}))
        rustc_env.setdefault("CARGO_CRATE_NAME", name_to_crate_name(name_to_pkg_name(name)))
        kwargs["rustc_env"] = rustc_env

    for variant in build_scripts:
        script_name = name
        script_kwargs = dict(kwargs) if split else kwargs
        if split:
            # Wildcard builds must select the target platform through the alias.
            if "manual" not in kwargs.get("tags", []):
                script_kwargs["tags"] = kwargs.get("tags", []) + ["manual"]
            representative = variant["target_triples"][0]
            script_name = "%s_%s" % (name, representative)
            for triple in variant["target_triples"]:
                branches[platform_label(triple, use_legacy_rules_rust_platforms)] = ":%s" % script_name

            # Distinct build.rs definitions need distinct metadata when their
            # binaries share an exec configuration.
            # https://github.com/hermeticbuild/rules_rs/issues/161
            script_kwargs["rustc_flags"] = kwargs.get("rustc_flags", []) + [
                "--codegen=metadata=-" + representative.replace("-", "_"),
            ]
        script_deps = variant["deps"]
        if variant["deps_by_platform"]:
            script_deps = script_deps + select(variant["deps_by_platform"] | {"//conditions:default": []})
        cargo_build_script(
            name = script_name,
            crate_features = crate_features + variant["crate_features"],
            deps = deps + script_deps,
            aliases = variant["aliases"] | aliases,
            **script_kwargs
        )
    if split:
        # This alias selects before cargo_build_script.script applies cfg=exec.
        native.alias(
            name = name,
            actual = select(branches),
            **{key: kwargs[key] for key in ["tags", "testonly", "visibility", "target_compatible_with"] if key in kwargs}
        )
