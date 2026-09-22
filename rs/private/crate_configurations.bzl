"""Share Cargo configurations without changing dependency labels."""

def _dependency_map(deps, platform_triples):
    return {platform_triple: dict(sorted(deps.get(platform_triple, {}).items())) for platform_triple in platform_triples}

def _configuration(fq, is_exec, resolution, exec_resolutions_by_cargo_target_triple, exec_platform_triples):
    features = {
        platform_triple: sorted([feature for feature in values if not feature.startswith("dep:")])
        for platform_triple, values in resolution.features_enabled.items()
    } if resolution.active else {}
    if is_exec:
        exec_build_deps = _dependency_map(resolution.build_deps, exec_platform_triples)
        build_deps = {platform_triple: exec_build_deps for platform_triple in features}
    else:
        build_deps = {}
        for platform_triple in features:
            execution = exec_resolutions_by_cargo_target_triple.get(platform_triple)
            triple_deps = execution.build_deps.get(fq, {}) if execution else {}
            build_deps[platform_triple] = _dependency_map(triple_deps, exec_platform_triples)
    return {
        "crate_features_by_triple": features,
        "deps_by_triple": _dependency_map(resolution.deps, features),
        "build_deps_by_triple": build_deps,
    }

def _dependency_labels(configuration):
    deps = set()
    for values in configuration["deps_by_triple"].values():
        deps.update(values)
    for deps_by_exec_triple in configuration["build_deps_by_triple"].values():
        for values in deps_by_exec_triple.values():
            deps.update(values)
    return deps

def _dependencies_invariant(deps_by_triple, invariant):
    for deps in deps_by_triple.values():
        for dep in deps:
            if dep not in invariant:
                return False
    return True

def _merge_configurations(configurations):
    result = {field: {} for field in configurations[0]}
    for configuration in configurations:
        for field, values in configuration.items():
            existing = result[field]
            for platform_triple, value in values.items():
                if platform_triple in existing and existing[platform_triple] != value:
                    return None
                existing[platform_triple] = value
    return result

def _share_build_deps(build_deps_by_triple):
    if not build_deps_by_triple:
        return build_deps_by_triple
    shared = build_deps_by_triple.values()[0]
    return {"": shared} | {platform_triple: deps for platform_triple, deps in build_deps_by_triple.items() if deps != shared}

def prepare_crate_configurations(
        target_resolutions,
        exec_resolutions_by_cargo_target_triple,
        dep_label_prefix,
        exec_platform_triples,
        preserve_cargo_target_triple = [],
        workspace_crates = []):
    """Clear cargo_target_triple for crates with invariant configurations and dependencies.

    Args:
        target_resolutions: Ordinary resolutions keyed by crate name/version.
        exec_resolutions_by_cargo_target_triple: Records keyed by the original cargo_target_triple,
            with resolutions by crate name/version and build_deps by crate name/version and exec_platform_triple.
        dep_label_prefix: Cargo dependency label prefix, such as "@crates//:".
        exec_platform_triples: Execution platforms supplied to the Cargo resolver.
        preserve_cargo_target_triple: Generated crates whose incoming cargo_target_triples must remain distinct.
        workspace_crates: Handwritten crates that preserve every incoming cargo_target_triple.

    Returns:
        Crate names/versions mapped to structs with cargo_target_triple_map and
        configurations. The map omits unchanged values; nonempty values can only
        clear. configurations is keyed by cargo_target_triple, with "" selecting
        the default/shared configuration. Its *_by_triple fields are keyed by
        the crate's compilation platform; build_deps_by_triple adds an inner
        execution-platform key. An empty outer build key supplies dependencies
        for compilation platforms without an explicit row.
        build_cargo_target_triple_required_on lists compilation triples whose
        build scripts must preserve the original cargo_target_triple.
    """
    cargo_target_triples = sorted(exec_resolutions_by_cargo_target_triple)
    clear_cargo_target_triples = {cargo_target_triple: "" for cargo_target_triple in cargo_target_triples}
    exec_platform_triples = sorted(exec_platform_triples)
    preserve_cargo_target_triple = set(preserve_cargo_target_triple)
    preserved_crates = preserve_cargo_target_triple | set(workspace_crates)
    configurations_by_crate = {}
    invariant = {}
    for fq, target in target_resolutions.items():
        configurations = {}
        if target.active:
            configurations[""] = _configuration(fq, False, target, exec_resolutions_by_cargo_target_triple, exec_platform_triples)
        for cargo_target_triple in cargo_target_triples:
            execution = exec_resolutions_by_cargo_target_triple[cargo_target_triple].resolutions[fq]
            if execution.active:
                configurations[cargo_target_triple] = _configuration(fq, True, execution, exec_resolutions_by_cargo_target_triple, exec_platform_triples)
        if not configurations:
            configurations[""] = _configuration(fq, False, target, exec_resolutions_by_cargo_target_triple, exec_platform_triples)
        shared_configuration = None if fq in preserved_crates else _merge_configurations(configurations.values())
        configurations_by_crate[fq] = configurations
        if shared_configuration != None:
            invariant[dep_label_prefix + fq] = struct(
                configuration = shared_configuration,
                deps = _dependency_labels(shared_configuration),
            )

    # Clearing a crate also requires every normal and build dependency to clear.
    # Handwritten dependency labels are absent from invariant.
    for _ in range(len(invariant) + 1):
        previous_size = len(invariant)
        for label, candidate in invariant.items():
            if not candidate.deps.issubset(invariant):
                invariant.pop(label)
        if len(invariant) == previous_size:
            break

    result = {}
    for fq, configurations in configurations_by_crate.items():
        candidate = invariant.get(dep_label_prefix + fq)
        if candidate:
            configurations = {"": candidate.configuration}
            cargo_target_triple_map = clear_cargo_target_triples
        else:
            first_triple = configurations.keys()[0]
            cargo_target_triple_map = {"": first_triple} if first_triple else {}
        for configuration in configurations.values():
            configuration["build_cargo_target_triple_required_on"] = [] if candidate else [
                platform_triple
                for platform_triple, deps_by_exec_triple in configuration["build_deps_by_triple"].items()
                if fq in preserve_cargo_target_triple or not _dependencies_invariant(deps_by_exec_triple, invariant)
            ]
            configuration["build_deps_by_triple"] = _share_build_deps(configuration["build_deps_by_triple"])
        if not candidate:
            first_configuration = configurations[first_triple]
            for cargo_target_triple in cargo_target_triples:
                configurations.setdefault(cargo_target_triple, first_configuration)
        result[fq] = struct(cargo_target_triple_map = cargo_target_triple_map, configurations = configurations)
    return result
