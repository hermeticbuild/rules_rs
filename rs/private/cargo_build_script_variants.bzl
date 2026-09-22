"""Select build-script features and dependencies before the exec transition."""

# buildifier: disable=bzl-visibility
load("@rules_rust//cargo/private:cargo_build_script.bzl", "name_to_crate_name", "name_to_pkg_name")
load("//rs:cargo_build_script.bzl", "cargo_build_script")
load(":cargo_select.bzl", "cargo_select")
load(":select_utils.bzl", "shared_and_per_platform")

def cargo_build_script_for_configurations(
        name,
        configurations,
        hub_name,
        preserve_context = False,
        crate_features = [],
        deps = [],
        aliases = {},
        use_legacy_rules_rust_platforms = False,
        **kwargs):
    """Select a build script before changing its compilation platform.

    An empty target triple in the build maps applies to every target triple.
    """
    scripts = {}
    for context, definition in configurations.items():
        build_deps = definition["build_deps_by_target"]
        common_deps = shared_and_per_platform(build_deps.get("", {}), use_legacy_rules_rust_platforms)
        for triple in sorted(definition["crate_features_select"]):
            script_deps, deps_by_platform = shared_and_per_platform(
                build_deps[triple],
                use_legacy_rules_rust_platforms,
            ) if triple in build_deps else common_deps
            recipe = {
                "crate_features": definition["crate_features_select"][triple],
                "deps": script_deps,
                "deps_by_platform": deps_by_platform,
                "context": (context or triple) if preserve_context else definition["build_contexts"].get(triple, ""),
            }
            key = json.encode(recipe)
            if key not in scripts:
                recipe["conditions"] = {}
                recipe["representative"] = context + "_" + triple if context else triple
                scripts[key] = recipe
            scripts[key]["conditions"].setdefault(context, []).append(triple)

    split = len(scripts) > 1
    script_kwargs = dict(kwargs)
    branches = {}
    if split:
        # Preserve the environment derived by rules_rust from the original name.
        if kwargs.get("pkg_name") == None:
            script_kwargs["pkg_name"] = name_to_pkg_name(name)
        rustc_env = dict(kwargs.get("rustc_env", {}))
        rustc_env.setdefault("CARGO_CRATE_NAME", name_to_crate_name(name_to_pkg_name(name)))
        script_kwargs["rustc_env"] = rustc_env
        if "manual" not in kwargs.get("tags", []):
            script_kwargs["tags"] = kwargs.get("tags", []) + ["manual"]

    for variant in scripts.values():
        script_name = name
        if split:
            representative = variant["representative"]
            script_name = name + "_" + representative
            for context, triples in variant["conditions"].items():
                by_triple = branches.setdefault(context, {})
                for triple in triples:
                    by_triple[triple] = ":" + script_name

            # Distinct build.rs definitions need distinct metadata when their
            # binaries share an exec configuration.
            # https://github.com/hermeticbuild/rules_rs/issues/161
            script_kwargs["rustc_flags"] = kwargs.get("rustc_flags", []) + [
                "--codegen=metadata=-" + representative.replace("-", "_"),
            ]
        if hub_name:
            script_kwargs["cargo_contexts"] = {context: variant["context"] for context in variant["conditions"] if context != variant["context"]}
        script_deps = list(variant["deps"])
        script_aliases = {dep: alias for dep, alias in variant["deps"].items() if alias} | aliases
        if variant["deps_by_platform"]:
            script_aliases = select({
                platform: script_aliases | {dep: alias for dep, alias in items.items() if alias} | aliases
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
