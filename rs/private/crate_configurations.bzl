"""Share Cargo configurations without changing dependency labels."""

def _dependency_map(deps, triples):
    return {triple: dict(sorted(deps.get(triple, {}).items())) for triple in triples}

def _definition(fq, is_exec, resolution, target_build_deps, exec_triples):
    features = {
        triple: sorted([feature for feature in values if not feature.startswith("dep:")])
        for triple, values in resolution.features_enabled.items()
    } if resolution.active else {}
    build_deps = {}
    if is_exec:
        exec_build_deps = _dependency_map(resolution.build_deps, exec_triples)
    for triple in features:
        if not is_exec:
            triple_deps = target_build_deps.get(triple, {}).get(fq, {})
            build_deps[triple] = _dependency_map(triple_deps, exec_triples)
        else:
            build_deps[triple] = exec_build_deps
    return {
        "crate_features_select": features,
        "deps_select": _dependency_map(resolution.deps, features),
        "build_deps_by_target": build_deps,
    }

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
        for deps in by_platform.values():
            if not _dependency_contexts_match(deps, requested, "", contexts_by_label):
                result[triple] = requested
                break
    return result

def _definitions_compatible(left, right):
    # _definition includes every execution triple in build_deps_by_target.
    for field, values in right.items():
        existing = left[field]
        for triple, value in values.items():
            if triple in existing and existing[triple] != value:
                return False
    return True

def _copy_definition(definition):
    return {field: dict(values) for field, values in definition.items()}

def _merge_definition(left, right):
    for field, values in right.items():
        left[field].update(values)

def prepare_crate_configurations(
        target_resolutions,
        exec_resolutions_by_target,
        target_build_deps,
        dep_label_prefix,
        preserve_context = [],
        workspace_crates = []):
    """Clear Cargo contexts when definitions and dependency configurations agree.

    Args:
        target_resolutions: Ordinary resolutions keyed by crate name/version.
        exec_resolutions_by_target: Execution resolutions keyed by original target triple.
        target_build_deps: Build dependencies keyed by target triple, owner, and execution triple.
        dep_label_prefix: Cargo dependency label prefix, such as "@crates//:".
        preserve_context: Generated crates whose incoming contexts must remain distinct.
        workspace_crates: Handwritten crates that preserve every incoming context.

    Returns:
        Crate names/versions mapped to dictionaries with context_map and definitions.
        context_map omits unchanged contexts; nonempty contexts can only clear.
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
    context_maps = {}
    for fq, target in target_resolutions.items():
        nodes = []
        if target.active:
            nodes.append(_resolution_node("", _definition(fq, False, target, target_build_deps, exec_triples)))
        for triple in target_triples:
            execution = exec_resolutions_by_target[triple][fq]
            if execution.active:
                nodes.append(_resolution_node(triple, _definition(fq, True, execution, target_build_deps, exec_triples)))
        if not nodes:
            nodes.append(_resolution_node("", _definition(fq, False, target, target_build_deps, exec_triples)))
        context_map = {node.context: node.context for node in nodes}
        preserve = fq in workspace_crates or fq in preserve_context
        if not preserve:
            context_map[nodes[0].context] = ""
            definition = _copy_definition(nodes[0].definition)
            for node in nodes:
                if node.context == nodes[0].context:
                    continue
                if _definitions_compatible(definition, node.definition):
                    context_map[node.context] = ""
                    _merge_definition(definition, node.definition)
        for context in target_triples:
            if context in context_map:
                continue
            nodes.append(struct(context = context, definition = nodes[0].definition, deps = nodes[0].deps, build_deps = nodes[0].build_deps))
            context_map[context] = context if preserve else ""
        context_map.setdefault("", context_map[nodes[0].context])
        nodes_by_crate[fq] = nodes
        context_maps[fq] = context_map

    contexts_by_label = {dep_label_prefix + fq: mapping for fq, mapping in context_maps.items()}

    # Removing a clear mapping can prevent a dependent crate from clearing too.
    for _ in range(len(nodes_by_crate) * len(contexts) + 1):
        changed = False
        for fq, nodes in nodes_by_crate.items():
            context_map = context_maps[fq]
            for node in nodes:
                if not node.context or context_map[node.context] or _can_clear_context(node, contexts_by_label):
                    continue
                changed = True
                if node.context == nodes[0].context:
                    # Keep the execution-only default and its source equivalent.
                    for context in contexts:
                        context_map[context] = context or node.context
                    break
                context_map[node.context] = node.context
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
                "context_map": {context: representative for context, representative in context_maps[fq].items() if context != representative},
                "definitions": definitions,
            }
        return result

    fail("Crate configuration refinement did not converge")
