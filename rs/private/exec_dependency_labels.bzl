"""Share compatible crate definitions across target and execution resolutions."""

def _maps_conflict(left, right, allow_new_keys):
    for key, value in right.items():
        if key not in left:
            if not allow_new_keys:
                return True
        elif left[key] != value:
            return True
    return False

def _nested_maps_conflict(left, right, allow_new_keys):
    for key, value in right.items():
        if key not in left:
            if not allow_new_keys:
                return True
        elif _maps_conflict(left[key], value, allow_new_keys):
            return True
    return False

def _aliases_for_deps(aliases, deps):
    result = {}
    for dep in aliases:
        for triple in deps:
            if dep in deps[triple]:
                result[dep] = aliases[dep]
                break
    return result

def _dependency_map(deps, triples):
    return {triple: deps.get(triple, []) for triple in triples}

def _resolution_node(fq, origin, resolution, target_build_deps, target_build_aliases, exec_triples, fallback = False):
    features = {
        triple: sorted([feature for feature in values if not feature.startswith("dep:")])
        for triple, values in resolution.features_enabled.items()
    }
    build_deps = {}
    build_aliases = {}
    if origin != None:
        exec_build_deps = _dependency_map(resolution.build_deps, exec_triples)
        exec_build_aliases = _aliases_for_deps(resolution.aliases, resolution.build_deps)
    for triple in features:
        if origin == None:
            triple_deps = target_build_deps.get(triple, {}).get(fq, {})
            build_deps[triple] = _dependency_map(triple_deps, exec_triples)
            build_aliases[triple] = target_build_aliases.get(triple, {}).get(fq, {})
        else:
            build_deps[triple] = exec_build_deps
            build_aliases[triple] = exec_build_aliases
    return struct(
        origin = origin,
        fallback = fallback,
        crate_features_select = features,
        deps_select = resolution.deps,
        aliases = _aliases_for_deps(resolution.aliases, resolution.deps),
        build_deps_by_target = build_deps,
        build_aliases_by_target = build_aliases,
    )

def _variant_labels(groups_by_crate, dep_label_prefix):
    labels = {}
    for fq, groups in groups_by_crate.items():
        exec_groups = 0
        for group in groups[1:]:
            if not group[0].fallback:
                exec_groups += 1
        for group in groups[1:]:
            first = group[0]
            if first.fallback:
                suffix = "_fallback"
                if first.origin != None:
                    suffix += "_" + first.origin
            else:
                suffix = "_exec" if exec_groups == 1 else "_exec_" + first.origin
            label = dep_label_prefix + "__exec/" + fq + suffix
            for node in group:
                labels.setdefault((node.fallback, node.origin), {})[dep_label_prefix + fq] = label
    return labels

def _remap_deps(deps, labels):
    return {triple: sorted([labels.get(dep, dep) for dep in values]) for triple, values in deps.items()}

def _remap_aliases(aliases, labels):
    return {labels.get(dep, dep): alias for dep, alias in aliases.items()}

def _remap_definition(node, variant_labels):
    labels = variant_labels.get((node.fallback, node.origin), {})
    build_deps = {}
    build_aliases = {}
    for triple, deps in node.build_deps_by_target.items():
        build_labels = variant_labels.get((node.fallback, triple), {}) if node.origin == None else labels
        build_deps[triple] = _remap_deps(deps, build_labels)
        build_aliases[triple] = _remap_aliases(node.build_aliases_by_target[triple], build_labels)
    return {
        "crate_features_select": dict(node.crate_features_select),
        "deps_select": _remap_deps(node.deps_select, labels),
        "aliases": _remap_aliases(node.aliases, labels),
        "build_deps_by_target": build_deps,
        "build_aliases_by_target": build_aliases,
    }

def _definitions_compatible(left, right, allow_new_keys):
    for field in ["crate_features_select", "deps_select", "aliases"]:
        if _maps_conflict(left[field], right[field], allow_new_keys):
            return False
    for field in ["build_deps_by_target", "build_aliases_by_target"]:
        if _nested_maps_conflict(left[field], right[field], allow_new_keys):
            return False
    return True

def _merge_definitions(left, right):
    for field in ["crate_features_select", "deps_select", "aliases"]:
        left[field].update(right[field])
    for field in ["build_deps_by_target", "build_aliases_by_target"]:
        for triple, values in right[field].items():
            left[field].setdefault(triple, {}).update(values)

def prepare_dependency_variants(target_resolutions, exec_resolutions_by_target, target_build_deps, target_build_aliases, dep_label_prefix, fallback = None):
    """Assign explicit labels to compatible target and execution definitions.

    Groups only split during refinement. Rewritten normal and build dependency
    labels must agree before two definitions can share a generated target.

    Args:
        target_resolutions: Ordinary feature resolutions keyed by crate name/version.
        exec_resolutions_by_target: Execution resolutions for the same crates, keyed by original target triple.
        target_build_deps: Build dependency matrices keyed by target triple, owner, and execution triple.
        target_build_aliases: Build dependency aliases keyed by target triple and owner.
        dep_label_prefix: Ordinary Cargo dependency label prefix, such as "@crates//:".
        fallback: Separate resolutions for otherwise inactive generated packages.

    Returns:
        A struct containing JSON-compatible variants_by_crate and
        exec_labels_by_target dictionaries.
    """
    target_triples = sorted(exec_resolutions_by_target)
    exec_triples = set()
    for resolutions in exec_resolutions_by_target.values():
        for resolution in resolutions.values():
            exec_triples.update(resolution.features_enabled)
    groups_by_crate = {}
    node_count = 0
    for fq, target in target_resolutions.items():
        nodes = []
        if target.active:
            nodes.append(_resolution_node(fq, None, target, target_build_deps, target_build_aliases, exec_triples))
        for triple in target_triples:
            execution = exec_resolutions_by_target[triple][fq]
            if execution.active:
                nodes.append(_resolution_node(fq, triple, execution, target_build_deps, target_build_aliases, exec_triples))
        if fallback:
            fallback_target = fallback.feature_resolutions_by_fq_crate[fq]
            if fallback_target.active:
                nodes.append(_resolution_node(fq, None, fallback_target, fallback.target_build_deps, fallback.target_build_aliases, exec_triples, fallback = True))
            for triple in target_triples:
                execution = fallback.exec_resolutions_by_target[triple][fq]
                if execution.active:
                    nodes.append(_resolution_node(fq, triple, execution, fallback.target_build_deps, fallback.target_build_aliases, exec_triples, fallback = True))
        if not nodes:
            nodes.append(_resolution_node(fq, None, target, target_build_deps, target_build_aliases, exec_triples))
        groups_by_crate[fq] = [nodes]
        node_count += len(nodes)

    for _ in range(node_count + 1):
        variant_labels = _variant_labels(groups_by_crate, dep_label_prefix)
        refined = {}
        variants = {}
        changed = False
        for fq, groups in groups_by_crate.items():
            refined[fq] = []
            variants[fq] = []
            for group in groups:
                new_groups = []
                definitions = []
                for node in group:
                    definition = _remap_definition(node, variant_labels)
                    matched = False
                    for index, merged in enumerate(definitions):
                        # Fallback definitions must not add aliases or platform
                        # definitions that change a primary target's analysis.
                        allow_new_keys = not node.fallback or new_groups[index][0].fallback
                        if _definitions_compatible(merged, definition, allow_new_keys):
                            new_groups[index].append(node)
                            _merge_definitions(merged, definition)
                            matched = True
                            break
                    if not matched:
                        new_groups.append([node])
                        definitions.append(definition)
                refined[fq].extend(new_groups)
                variants[fq].extend(definitions)
                changed = changed or len(new_groups) > 1
        if not changed:
            for fq, definitions in variants.items():
                for index, definition in enumerate(definitions):
                    definition["name_suffix"] = ""
                    if index:
                        node = groups_by_crate[fq][index][0]
                        label = variant_labels[(node.fallback, node.origin)][dep_label_prefix + fq]
                        definition["name_suffix"] = label.removeprefix(dep_label_prefix + "__exec/" + fq)
            return struct(
                variants_by_crate = variants,
                exec_labels_by_target = {triple: variant_labels.get((False, triple), {}) for triple in target_triples},
            )
        groups_by_crate = refined

    fail("Crate definition refinement did not converge")
