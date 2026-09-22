"""Share Cargo configurations without changing dependency labels."""

def _aliases_for_deps(aliases, deps):
    result = {}
    for dep in aliases:
        for values in deps.values():
            if dep in values:
                result[dep] = aliases[dep]
                break
    return result

def _dependency_map(deps, triples):
    return {triple: sorted(deps.get(triple, [])) for triple in triples}

def _definition(fq, is_exec, resolution, target_build_deps, target_build_aliases, exec_triples):
    features = {
        triple: sorted([feature for feature in values if not feature.startswith("dep:")])
        for triple, values in resolution.features_enabled.items()
    } if resolution.active else {}
    deps = {triple: sorted(values) for triple, values in resolution.deps.items() if triple in features}
    build_deps = {}
    build_aliases = {}
    if is_exec:
        exec_build_deps = _dependency_map(resolution.build_deps, exec_triples)
        exec_build_aliases = _aliases_for_deps(resolution.aliases, resolution.build_deps)
    for triple in features:
        if not is_exec:
            triple_deps = target_build_deps.get(triple, {}).get(fq, {})
            build_deps[triple] = _dependency_map(triple_deps, exec_triples)
            build_aliases[triple] = target_build_aliases.get(triple, {}).get(fq, {})
        else:
            build_deps[triple] = exec_build_deps
            build_aliases[triple] = exec_build_aliases
    return {
        "crate_features_select": features,
        "deps_select": deps,
        "aliases": _aliases_for_deps(resolution.aliases, deps),
        "build_deps_by_target": build_deps,
        "build_aliases_by_target": build_aliases,
    }

def _context_maps(nodes_by_crate, cleared):
    result = {}
    for fq, nodes in nodes_by_crate.items():
        context_map = {"": "" if nodes[0].context in cleared[fq] else nodes[0].context}
        for node in nodes:
            context_map[node.context] = "" if node.context in cleared[fq] else node.context
        result[fq] = context_map
    return result

def _dependency_contexts_match(deps, original, representative, contexts_by_label):
    if original == representative:
        return True
    for dep in deps:
        context_map = contexts_by_label.get(dep)

        # Handwritten targets can select dependencies using the original context.
        if context_map == None or context_map.get(original, original) != context_map.get(representative, representative):
            return False
    return True

def _resolution_node(context, definition):
    # Compare each dependency once, even when multiple platforms use it.
    deps = set()
    for values in definition["deps_select"].values():
        deps.update(values)
    build_deps = {}
    for triple, by_platform in definition["build_deps_by_target"].items():
        labels = set()
        for values in by_platform.values():
            labels.update(values)
        if labels:
            build_deps[triple] = labels
    return struct(context = context, definition = definition, deps = deps, build_deps = build_deps)

def _can_clear_context(node, contexts_by_label):
    if not node.context:
        return True
    if not _dependency_contexts_match(node.deps, node.context, "", contexts_by_label):
        return False
    for triple, deps in node.build_deps.items():
        if not _dependency_contexts_match(deps, node.context, triple, contexts_by_label):
            return False
    return True

def _build_contexts(context, definition, contexts_by_label):
    result = {}
    for triple, by_platform in definition["build_deps_by_target"].items():
        requested = context or triple
        result[triple] = ""
        for deps in by_platform.values():
            if not _dependency_contexts_match(deps, requested, "", contexts_by_label):
                result[triple] = requested
                break
    return result

def _maps_compatible(left, right):
    for key, value in right.items():
        if key in left and left[key] != value:
            return False
    return True

def _definitions_compatible(left, right):
    # Keep alias maps equal when sharing definitions across platforms.
    if left["aliases"] != right["aliases"]:
        return False
    for field in ["crate_features_select", "deps_select"]:
        if not _maps_compatible(left[field], right[field]):
            return False
    for field in ["build_deps_by_target", "build_aliases_by_target"]:
        for triple, values in right[field].items():
            if triple in left[field] and not _maps_compatible(left[field][triple], values):
                return False
    return True

def _copy_definition(definition):
    return {
        field: dict(definition[field])
        for field in ["crate_features_select", "deps_select", "aliases"]
    } | {
        field: {triple: dict(values) for triple, values in definition[field].items()}
        for field in ["build_deps_by_target", "build_aliases_by_target"]
    }

def _merge_definition(left, right):
    for field in ["crate_features_select", "deps_select"]:
        left[field].update(right[field])
    for field in ["build_deps_by_target", "build_aliases_by_target"]:
        for triple, values in right[field].items():
            if triple not in left[field]:
                left[field][triple] = dict(values)
            else:
                left[field][triple].update(values)

def prepare_crate_configurations(
        target_resolutions,
        exec_resolutions_by_target,
        target_build_deps,
        target_build_aliases,
        dep_label_prefix,
        preserve_context = [],
        workspace_crates = []):
    """Clear Cargo contexts when definitions and dependency configurations agree.

    Args:
        target_resolutions: Ordinary resolutions keyed by crate name/version.
        exec_resolutions_by_target: Execution resolutions keyed by original target triple.
        target_build_deps: Build dependencies keyed by target triple, owner, and execution triple.
        target_build_aliases: Build aliases keyed by target triple and owner.
        dep_label_prefix: Cargo dependency label prefix, such as "@crates//:".
        preserve_context: Generated crates whose incoming contexts must remain distinct.
        workspace_crates: Handwritten crates that preserve every incoming context.

    Returns:
        Crate names/versions mapped to dictionaries with context_map and definitions.
        Nonempty contexts map to themselves or the default configuration.
        definitions maps retained contexts to JSON-compatible crate definitions.
    """
    target_triples = sorted(exec_resolutions_by_target)
    exec_triples = set()
    for resolutions in exec_resolutions_by_target.values():
        for resolution in resolutions.values():
            exec_triples.update(resolution.features_enabled)
    exec_triples = sorted(exec_triples)
    contexts = [""] + target_triples
    preserve_context = set(preserve_context)
    workspace_crates = set(workspace_crates)
    nodes_by_crate = {}
    cleared = {}
    node_count = 0
    for fq, target in target_resolutions.items():
        nodes = []
        if target.active:
            nodes.append(_resolution_node("", _definition(fq, False, target, target_build_deps, target_build_aliases, exec_triples)))
        for triple in target_triples:
            execution = exec_resolutions_by_target[triple][fq]
            if execution.active:
                nodes.append(_resolution_node(triple, _definition(fq, True, execution, target_build_deps, target_build_aliases, exec_triples)))
        if not nodes:
            nodes.append(_resolution_node("", _definition(fq, False, target, target_build_deps, target_build_aliases, exec_triples)))
        cleared[fq] = set()
        if fq not in workspace_crates and fq not in preserve_context:
            cleared[fq].add(nodes[0].context)
            definition = _copy_definition(nodes[0].definition)
            for node in nodes:
                if node.context == nodes[0].context:
                    continue
                if _definitions_compatible(definition, node.definition):
                    cleared[fq].add(node.context)
                    _merge_definition(definition, node.definition)
        defined_contexts = set([node.context for node in nodes])
        for context in contexts:
            if context in defined_contexts or (not context and fq not in workspace_crates):
                continue
            nodes.append(struct(context = context, definition = nodes[0].definition, deps = nodes[0].deps, build_deps = nodes[0].build_deps))
            if nodes[0].context in cleared[fq]:
                cleared[fq].add(context)
        nodes_by_crate[fq] = nodes
        node_count += len(nodes)

    # Removing a clear mapping can prevent a dependent crate from clearing too.
    for _ in range(node_count + 1):
        context_maps = _context_maps(nodes_by_crate, cleared)
        contexts_by_label = {dep_label_prefix + fq: mapping for fq, mapping in context_maps.items()}
        changed = False
        for fq, nodes in nodes_by_crate.items():
            for node in nodes:
                if node.context not in cleared[fq] or _can_clear_context(node, contexts_by_label):
                    continue
                cleared[fq].remove(node.context)
                changed = True
            if cleared[fq] and nodes[0].context not in cleared[fq]:
                # An execution-only crate's default must be a fixed point too.
                cleared[fq].clear()
                changed = True
        if changed:
            continue

        result = {}
        for fq, nodes in nodes_by_crate.items():
            definitions = {}
            for node in nodes:
                context = context_maps[fq][node.context]
                if context not in definitions:
                    definitions[context] = _copy_definition(node.definition)
                elif not node.context or exec_resolutions_by_target[node.context][fq].active:
                    # Missing resolutions reuse the first definition, already merged.
                    _merge_definition(definitions[context], node.definition)
            for context, definition in definitions.items():
                definition["build_contexts"] = {
                    triple: context or triple
                    for triple in definition["build_deps_by_target"]
                } if fq in preserve_context else _build_contexts(context, definition, contexts_by_label)
            result[fq] = {
                "context_map": context_maps[fq],
                "definitions": definitions,
                "preserve_context": fq in preserve_context or fq in workspace_crates,
            }
        return result

    fail("Crate configuration refinement did not converge")
