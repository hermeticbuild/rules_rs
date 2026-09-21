"""Select build-script features and dependencies before the exec transition."""

# buildifier: disable=bzl-visibility
load("@rules_rust//cargo/private:cargo_build_script.bzl", "name_to_crate_name", "name_to_pkg_name")
load("//rs:cargo_build_script.bzl", "cargo_build_script")
load(":select_utils.bzl", "platform_label", "shared_and_per_platform")

def build_script_variants(profiles):
    """Group target triples with equal build-script features, deps, and aliases.

    Args:
        profiles: Features, execution-platform dependencies, and aliases by target triple.

    Returns:
        Dictionaries containing triples, crate_features, deps, and aliases. The
        deps dictionary remains indexed by execution triple.
    """
    if not profiles:
        profiles = {"": {"features": [], "deps": {}, "aliases": {}}}
    variants = {}
    for triple in sorted(profiles):
        profile = profiles[triple]
        deps = profile["deps"]
        aliases = profile["aliases"]
        recipe = {
            "crate_features": sorted(set(profile["features"])),
            "deps": {host: sorted(set(deps[host])) for host in sorted(deps)} if any(deps.values()) else {},
            "aliases": {label: aliases[label] for label in sorted(aliases)},
        }
        key = json.encode(recipe)
        if key not in variants:
            variants[key] = dict(recipe, triples = [])
        variants[key]["triples"].append(triple)
    return variants.values()

def cargo_build_script_for_targets(
        name,
        profiles,
        crate_features = [],
        deps = [],
        aliases = {},
        use_legacy_rules_rust_platforms = False,
        **kwargs):
    """Declare build scripts selected in the original target configuration.

    Args:
        name: Build-script target name.
        profiles: Features, execution-platform dependencies, and aliases by target triple.
        crate_features: Features shared by every target triple.
        deps: Additional dependencies shared by every target triple.
        aliases: Additional dependency aliases shared by every target triple.
        use_legacy_rules_rust_platforms: Whether to use rules_rust platform labels.
        **kwargs: Remaining cargo_build_script arguments.
    """

    # Shared crate_features, deps, and aliases do not affect grouping.
    variants = build_script_variants(profiles)
    split = len(variants) > 1
    if split:
        # Preserve the environment derived by rules_rust from the original name.
        if kwargs.get("pkg_name") == None:
            kwargs["pkg_name"] = name_to_pkg_name(name)
        rustc_env = dict(kwargs.get("rustc_env", {}))
        rustc_env.setdefault("CARGO_CRATE_NAME", name_to_crate_name(name_to_pkg_name(name)))
        kwargs["rustc_env"] = rustc_env

    branches = {}
    for variant in variants:
        script_name = name
        script_kwargs = dict(kwargs)
        if split:
            # Wildcard builds must select the target platform through the alias.
            if "manual" not in kwargs.get("tags", []):
                script_kwargs["tags"] = kwargs.get("tags", []) + ["manual"]
            representative = variant["triples"][0]
            script_name = "%s_%s" % (name, representative)
            for triple in variant["triples"]:
                branches[platform_label(triple, use_legacy_rules_rust_platforms)] = ":%s" % script_name

            # Distinct build.rs definitions need distinct metadata when their
            # binaries share an exec configuration.
            # https://github.com/hermeticbuild/rules_rs/issues/161
            script_kwargs["rustc_flags"] = kwargs.get("rustc_flags", []) + [
                "--codegen=metadata=-" + representative.replace("-", "_"),
            ]
        script_deps, conditional_deps = shared_and_per_platform(variant["deps"], use_legacy_rules_rust_platforms)
        if conditional_deps:
            script_deps += select(conditional_deps | {"//conditions:default": []})
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
