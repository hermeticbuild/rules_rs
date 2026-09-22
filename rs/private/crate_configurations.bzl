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

def _dependency_target_triples_match(deps, cargo_target_triple, mapped_target_triple, cargo_target_triple_maps_by_label):
    if cargo_target_triple == mapped_target_triple:
        return True
    for dep in deps:
        cargo_target_triple_map = cargo_target_triple_maps_by_label.get(dep)

        # Handwritten targets can select dependencies using cargo_target_triple.
        if cargo_target_triple_map == None or cargo_target_triple_map.get(cargo_target_triple, cargo_target_triple) != cargo_target_triple_map.get(mapped_target_triple, mapped_target_triple):
            return False
    return True

def _resolution_node(cargo_target_triple, configuration):
    # Compare each dependency once, even when multiple platforms use it.
    deps = set()
    for values in configuration["deps_by_triple"].values():
        deps.update(values)
    build_deps = {}
    for platform_triple, deps_by_exec_triple in configuration["build_deps_by_triple"].items():
        labels = set()
        for values in deps_by_exec_triple.values():
            labels.update(values)
        if labels:
            build_deps[platform_triple] = labels
    return struct(cargo_target_triple = cargo_target_triple, configuration = configuration, deps = deps, build_deps = build_deps)

def _can_clear_cargo_target_triple(node, cargo_target_triple_maps_by_label):
    if not _dependency_target_triples_match(node.deps, node.cargo_target_triple, "", cargo_target_triple_maps_by_label):
        return False
    for platform_triple, deps in node.build_deps.items():
        if not _dependency_target_triples_match(deps, node.cargo_target_triple, platform_triple, cargo_target_triple_maps_by_label):
            return False
    return True

def _build_cargo_target_triple_required_on(cargo_target_triple, configuration, cargo_target_triple_maps_by_label):
    result = []
    for platform_triple, deps_by_exec_triple in configuration["build_deps_by_triple"].items():
        requested = cargo_target_triple or platform_triple
        for deps in deps_by_exec_triple.values():
            if not _dependency_target_triples_match(deps, requested, "", cargo_target_triple_maps_by_label):
                result.append(platform_triple)
                break
    return result

def _configurations_compatible(left, right):
    # _configuration includes every exec_platform_triple in build_deps_by_triple.
    for field, values in right.items():
        existing = left[field]
        for platform_triple, value in values.items():
            if platform_triple in existing and existing[platform_triple] != value:
                return False
    return True

def _copy_configuration(configuration):
    return {field: dict(values) for field, values in configuration.items()}

def _merge_configuration(left, right):
    for field, values in right.items():
        left[field].update(values)

def _share_build_deps(build_deps_by_triple):
    if not build_deps_by_triple:
        return build_deps_by_triple
    shared = build_deps_by_triple.values()[0]
    return {"": shared} | {platform_triple: deps for platform_triple, deps in build_deps_by_triple.items() if deps != shared}

def prepare_crate_configurations(
        target_resolutions,
        exec_resolutions_by_cargo_target_triple,
        dep_label_prefix,
        preserve_cargo_target_triple = [],
        workspace_crates = []):
    """Clear cargo_target_triple when crate and dependency configurations agree.

    Args:
        target_resolutions: Ordinary resolutions keyed by crate name/version.
        exec_resolutions_by_cargo_target_triple: Records keyed by the original cargo_target_triple,
            with resolutions by crate name/version and build_deps by crate name/version and exec_platform_triple.
        dep_label_prefix: Cargo dependency label prefix, such as "@crates//:".
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
    exec_platform_triples = set()
    for execution in exec_resolutions_by_cargo_target_triple.values():
        for resolution in execution.resolutions.values():
            exec_platform_triples.update(resolution.features_enabled)
    exec_platform_triples = sorted(exec_platform_triples)
    cargo_target_values = [""] + cargo_target_triples
    preserve_cargo_target_triple = set(preserve_cargo_target_triple)
    workspace_crates = set(workspace_crates)
    crates = {}
    for fq, target in target_resolutions.items():
        nodes = []
        if target.active:
            nodes.append(_resolution_node("", _configuration(fq, False, target, exec_resolutions_by_cargo_target_triple, exec_platform_triples)))
        for cargo_target_triple in cargo_target_triples:
            execution = exec_resolutions_by_cargo_target_triple[cargo_target_triple].resolutions[fq]
            if execution.active:
                nodes.append(_resolution_node(cargo_target_triple, _configuration(fq, True, execution, exec_resolutions_by_cargo_target_triple, exec_platform_triples)))
        if not nodes:
            nodes.append(_resolution_node("", _configuration(fq, False, target, exec_resolutions_by_cargo_target_triple, exec_platform_triples)))
        cargo_target_triple_map = {node.cargo_target_triple: node.cargo_target_triple for node in nodes}
        preserve = fq in workspace_crates or fq in preserve_cargo_target_triple
        if not preserve:
            cargo_target_triple_map[nodes[0].cargo_target_triple] = ""
            configuration = _copy_configuration(nodes[0].configuration)
            for node in nodes:
                if node.cargo_target_triple == nodes[0].cargo_target_triple:
                    continue
                if _configurations_compatible(configuration, node.configuration):
                    cargo_target_triple_map[node.cargo_target_triple] = ""
                    _merge_configuration(configuration, node.configuration)
        for cargo_target_triple in cargo_target_triples:
            if cargo_target_triple in cargo_target_triple_map:
                continue
            nodes.append(struct(cargo_target_triple = cargo_target_triple, configuration = nodes[0].configuration, deps = nodes[0].deps, build_deps = nodes[0].build_deps))
            cargo_target_triple_map[cargo_target_triple] = cargo_target_triple if preserve else ""
        cargo_target_triple_map.setdefault("", cargo_target_triple_map[nodes[0].cargo_target_triple])
        crates[fq] = struct(nodes = nodes, cargo_target_triple_map = cargo_target_triple_map)

    cargo_target_triple_maps_by_label = {dep_label_prefix + fq: crate.cargo_target_triple_map for fq, crate in crates.items()}

    # Removing a clear mapping can prevent a dependent crate from clearing too.
    for _ in range(len(crates) * len(cargo_target_values) + 1):
        changed = False
        for crate in crates.values():
            cargo_target_triple_map = crate.cargo_target_triple_map
            for node in crate.nodes:
                if not node.cargo_target_triple or cargo_target_triple_map[node.cargo_target_triple] or _can_clear_cargo_target_triple(node, cargo_target_triple_maps_by_label):
                    continue
                changed = True
                if node.cargo_target_triple == crate.nodes[0].cargo_target_triple:
                    # Keep the execution-only default and its source equivalent.
                    for cargo_target_triple in cargo_target_values:
                        cargo_target_triple_map[cargo_target_triple] = cargo_target_triple or node.cargo_target_triple
                    break
                cargo_target_triple_map[node.cargo_target_triple] = node.cargo_target_triple
        if changed:
            continue

        result = {}
        for fq, crate in crates.items():
            configurations = {}
            for node in crate.nodes:
                cargo_target_triple = crate.cargo_target_triple_map[node.cargo_target_triple]
                if cargo_target_triple not in configurations:
                    configurations[cargo_target_triple] = _copy_configuration(node.configuration)
                elif not node.cargo_target_triple or exec_resolutions_by_cargo_target_triple[node.cargo_target_triple].resolutions[fq].active:
                    # Missing resolutions reuse the first configuration, already merged.
                    _merge_configuration(configurations[cargo_target_triple], node.configuration)
            for cargo_target_triple, configuration in configurations.items():
                configuration["build_cargo_target_triple_required_on"] = list(configuration["build_deps_by_triple"]) if fq in preserve_cargo_target_triple else _build_cargo_target_triple_required_on(cargo_target_triple, configuration, cargo_target_triple_maps_by_label)
                configuration["build_deps_by_triple"] = _share_build_deps(configuration["build_deps_by_triple"])
            result[fq] = struct(
                cargo_target_triple_map = {cargo_target_triple: mapped_target_triple for cargo_target_triple, mapped_target_triple in crate.cargo_target_triple_map.items() if cargo_target_triple != mapped_target_triple},
                configurations = configurations,
            )
        return result

    fail("Crate configuration refinement did not converge")
