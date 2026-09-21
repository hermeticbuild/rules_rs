"""Select build-script features and dependencies before the exec transition."""

# buildifier: disable=bzl-visibility
load("@rules_rust//cargo/private:cargo_build_script.bzl", "name_to_crate_name", "name_to_pkg_name")
load("//rs:cargo_build_script.bzl", "cargo_build_script")
load(":select_utils.bzl", "compute_select")

def _platform(triple, use_legacy_rules_rust_platforms):
    if use_legacy_rules_rust_platforms:
        return "@rules_rust//rust/platform:" + triple.replace("-musl", "-gnu").replace("-gnullvm", "-msvc")
    return "@rules_rs//rs/platforms/config:" + triple

def build_script_variants(
        triples,
        conditional_crate_features = {},
        deps_by_target = {},
        aliases_by_target = {}):
    """Group target triples with equal build-script features, deps, and aliases.

    Args:
        triples: Original target triples.
        conditional_crate_features: Additional build-script features by target triple.
        deps_by_target: Dependency labels by target triple, then execution triple.
        aliases_by_target: Dependency aliases by target triple.

    Returns:
        Dictionaries containing triples, crate_features, deps, and aliases. The
        deps dictionary remains indexed by execution triple.
    """
    variants = {}
    for triple in sorted(triples or [""]):
        deps = deps_by_target.get(triple, {})
        aliases = aliases_by_target.get(triple, {})
        recipe = {
            "crate_features": sorted(set(conditional_crate_features.get(triple, []))),
            "deps": {host: sorted(set(deps[host])) for host in sorted(deps)} if any(deps.values()) else {},
            "aliases": {label: aliases[label] for label in sorted(aliases)},
        }
        key = json.encode(recipe)
        if key not in variants:
            variants[key] = dict(recipe, triples = [])
        variants[key]["triples"].append(triple)
    return variants.values()

def _execution_deps(deps, use_legacy_rules_rust_platforms):
    by_platform = {}
    for triple, labels in deps.items():
        platform = _platform(triple, use_legacy_rules_rust_platforms)
        by_platform.setdefault(platform, []).extend(labels)
    common, branches = compute_select([], by_platform)
    if branches:
        return sorted(common) + select(branches | {"//conditions:default": []})
    return sorted(common)

def cargo_build_script_for_targets(
        name,
        triples,
        crate_features = [],
        conditional_crate_features = {},
        deps = [],
        aliases = {},
        deps_by_target = {},
        aliases_by_target = {},
        use_legacy_rules_rust_platforms = False,
        **kwargs):
    """Declare build scripts selected in the original target configuration.

    Args:
        name: Build-script target name.
        triples: Original target triples.
        crate_features: Features shared by every target triple.
        conditional_crate_features: Additional features by target triple.
        deps: Additional dependencies shared by every target triple.
        aliases: Additional dependency aliases shared by every target triple.
        deps_by_target: Dependency labels by target triple, then execution triple.
        aliases_by_target: Dependency aliases by target triple.
        use_legacy_rules_rust_platforms: Whether to use rules_rust platform labels.
        **kwargs: Remaining cargo_build_script arguments.
    """

    # Shared crate_features, deps, and aliases do not affect grouping.
    variants = build_script_variants(
        triples,
        conditional_crate_features,
        deps_by_target,
        aliases_by_target,
    )
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
            representative = variant["triples"][0]
            script_name = "%s_%s" % (name, representative)
            for triple in variant["triples"]:
                branches[_platform(triple, use_legacy_rules_rust_platforms)] = ":%s" % script_name

            # Distinct build.rs definitions need distinct metadata when their
            # binaries share an exec configuration.
            # https://github.com/hermeticbuild/rules_rs/issues/161
            script_kwargs["rustc_flags"] = kwargs.get("rustc_flags", []) + [
                "--codegen=metadata=-%s" % representative.replace("-", "_"),
            ]
        cargo_build_script(
            name = script_name,
            crate_features = crate_features + variant["crate_features"],
            deps = deps + _execution_deps(variant["deps"], use_legacy_rules_rust_platforms),
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
