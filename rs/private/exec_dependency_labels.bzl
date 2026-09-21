"""Share compatible crate definitions across target and execution resolutions."""

def _maps_conflict(left, right):
    for key, value in right.items():
        if key in left and left[key] != value:
            return True
    return False

def _nested_maps_conflict(left, right):
    for key, value in right.items():
        if key in left and _maps_conflict(left[key], value):
            return True
    return False

def _aliases_for_deps(aliases, deps):
    labels = set([dep for values in deps.values() for dep in values])
    return {dep: alias for dep, alias in aliases.items() if dep in labels}

def _dependency_map(deps, triples):
    return {triple: sorted(deps.get(triple, [])) for triple in triples}

def _resolution_node(fq, origin, resolution, target_build_deps, target_build_aliases, exec_triples):
    features = {
        triple: sorted([feature for feature in values if not feature.startswith("dep:")])
        for triple, values in resolution.features_enabled.items()
    }
    deps = _dependency_map(resolution.deps, features)
    build_deps = {}
    build_aliases = {}
    if origin != None:
        exec_build_deps = _dependency_map(resolution.build_deps, exec_triples)
        exec_build_aliases = _aliases_for_deps(resolution.aliases, resolution.build_deps)
    for triple in features:
        if origin == None:
            triple_deps = target_build_deps.get(triple, {}).get(fq, {})
            triple_aliases = target_build_aliases.get(triple, {}).get(fq, {})
            build_deps[triple] = _dependency_map(triple_deps, exec_triples)
            build_aliases[triple] = _aliases_for_deps(triple_aliases, triple_deps)
        else:
            build_deps[triple] = exec_build_deps
            build_aliases[triple] = exec_build_aliases
    return struct(
        origin = origin,
        crate_features_select = features,
        deps_select = deps,
        aliases = _aliases_for_deps(resolution.aliases, deps),
        build_deps_by_target = build_deps,
        build_aliases_by_target = build_aliases,
    )

def _variant_suffix(groups, index):
    if index == 0:
        return ""
    if len(groups) == 2:
        return "_exec"
    return "_exec_" + groups[index][0].origin

def _execution_labels(groups_by_crate, target_triples, dep_label_prefix):
    labels = {triple: {} for triple in target_triples}
    for fq, groups in groups_by_crate.items():
        for group in groups[1:]:
            label = dep_label_prefix + "__exec/" + group[0].origin + "/" + fq
            for node in group:
                labels[node.origin][dep_label_prefix + fq] = label
    return labels

def _remap_deps(deps, labels):
    return {triple: sorted([labels.get(dep, dep) for dep in values]) for triple, values in deps.items()}

def _remap_aliases(aliases, labels):
    return {labels.get(dep, dep): alias for dep, alias in aliases.items()}

def _remap_definition(node, exec_labels):
    labels = exec_labels.get(node.origin, {})
    build_deps = {}
    build_aliases = {}
    for triple, deps in node.build_deps_by_target.items():
        build_labels = exec_labels.get(triple if node.origin == None else node.origin, {})
        build_deps[triple] = _remap_deps(deps, build_labels)
        build_aliases[triple] = _remap_aliases(node.build_aliases_by_target[triple], build_labels)
    return {
        "crate_features_select": node.crate_features_select,
        "deps_select": _remap_deps(node.deps_select, labels),
        "aliases": _remap_aliases(node.aliases, labels),
        "build_deps_by_target": build_deps,
        "build_aliases_by_target": build_aliases,
    }

def _definitions_compatible(left, right):
    for field in ["crate_features_select", "deps_select", "aliases"]:
        if _maps_conflict(left[field], right[field]):
            return False
    for field in ["build_deps_by_target", "build_aliases_by_target"]:
        if _nested_maps_conflict(left[field], right[field]):
            return False
    return True

def _merge_definitions(left, right):
    result = {
        field: left[field] | right[field]
        for field in ["crate_features_select", "deps_select", "aliases"]
    }
    for field in ["build_deps_by_target", "build_aliases_by_target"]:
        result[field] = dict(left[field])
        for triple, values in right[field].items():
            result[field][triple] = result[field].get(triple, {}) | values
    return result

def prepare_dependency_variants(target_resolutions, exec_resolutions_by_target, target_build_deps, target_build_aliases, dep_label_prefix):
    """Assign explicit labels to compatible target and execution definitions.

    Groups only split during refinement. Rewritten normal and build dependency
    labels must agree before two definitions can share a generated target.

    Args:
        target_resolutions: Ordinary feature resolutions keyed by crate name/version.
        exec_resolutions_by_target: Execution resolutions keyed by original target triple.
        target_build_deps: Build dependency matrices keyed by target triple, owner, and execution triple.
        target_build_aliases: Build dependency aliases keyed by target triple and owner.
        dep_label_prefix: Ordinary Cargo dependency label prefix, such as "@crates//:".

    Returns:
        A struct containing JSON-compatible variants_by_crate,
        exec_labels_by_target, and exec_aliases_by_crate dictionaries.
    """
    target_triples = sorted(exec_resolutions_by_target)
    crate_names = set(target_resolutions)
    exec_triples = set()
    for resolutions in exec_resolutions_by_target.values():
        crate_names.update(resolutions)
        for resolution in resolutions.values():
            exec_triples.update(resolution.features_enabled)
    for owners in target_build_deps.values():
        for deps in owners.values():
            exec_triples.update(deps)
    exec_triples = sorted(exec_triples)

    groups_by_crate = {}
    node_count = 0
    for fq in sorted(crate_names):
        nodes = []
        target = target_resolutions.get(fq)
        if target and target.active:
            nodes.append(_resolution_node(fq, None, target, target_build_deps, target_build_aliases, exec_triples))
        for triple in target_triples:
            execution = exec_resolutions_by_target[triple].get(fq)
            if execution and execution.active:
                nodes.append(_resolution_node(fq, triple, execution, target_build_deps, target_build_aliases, exec_triples))
        if not nodes and target:
            nodes.append(_resolution_node(fq, None, target, target_build_deps, target_build_aliases, exec_triples))
        if nodes:
            groups_by_crate[fq] = [nodes]
            node_count += len(nodes)

    for _ in range(node_count + 1):
        exec_labels = _execution_labels(groups_by_crate, target_triples, dep_label_prefix)
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
                    definition = _remap_definition(node, exec_labels)
                    matched = False
                    for index, merged in enumerate(definitions):
                        if _definitions_compatible(merged, definition):
                            new_groups[index].append(node)
                            definitions[index] = _merge_definitions(merged, definition)
                            matched = True
                            break
                    if not matched:
                        new_groups.append([node])
                        definitions.append(definition)
                refined[fq].extend(new_groups)
                variants[fq].extend(definitions)
                changed = changed or len(new_groups) > 1
        if not changed:
            exec_aliases = {}
            for fq, definitions in variants.items():
                exec_aliases[fq] = {}
                for index, definition in enumerate(definitions):
                    definition["name_suffix"] = _variant_suffix(groups_by_crate[fq], index)
                    if index:
                        origin = groups_by_crate[fq][index][0].origin
                        label = exec_labels[origin][dep_label_prefix + fq]
                        exec_aliases[fq][label] = definition["name_suffix"]
            return struct(
                variants_by_crate = variants,
                exec_labels_by_target = exec_labels,
                exec_aliases_by_crate = exec_aliases,
            )
        groups_by_crate = refined

    fail("Crate definition refinement did not converge")
