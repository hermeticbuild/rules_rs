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

def _context_maps(groups_by_crate, contexts):
    result = {}
    for fq, groups in groups_by_crate.items():
        context_map = {context: groups[0][0].context for context in contexts}
        for group in groups:
            for node in group:
                context_map[node.context] = group[0].context
        result[fq] = context_map
    return result

def _dependency_context(label, context, contexts_by_label):
    context_map = contexts_by_label.get(label)
    if context_map == None:
        # Handwritten targets can select dependencies using the original context.
        return context
    return context_map.get(context, context)

def _dependency_contexts_match(deps, original, representative, contexts_by_label):
    if original == representative:
        return True
    for dep in deps:
        if _dependency_context(dep, original, contexts_by_label) != _dependency_context(dep, representative, contexts_by_label):
            return False
    return True

def _can_inherit_context(node, representative, contexts_by_label):
    definition = node.definition
    for deps in definition["deps_select"].values():
        if not _dependency_contexts_match(deps, node.context, representative, contexts_by_label):
            return False
    for triple, by_platform in definition["build_deps_by_target"].items():
        original = node.context or triple
        build_representative = representative or triple
        for deps in by_platform.values():
            if not _dependency_contexts_match(deps, original, build_representative, contexts_by_label):
                return False
    return True

def _build_contexts(context, definition, contexts, contexts_by_label):
    result = {}
    for triple, by_platform in definition["build_deps_by_target"].items():
        requested = context or triple
        result[triple] = requested
        deps = set()
        for values in by_platform.values():
            deps.update(values)
        for representative in contexts:
            if _dependency_contexts_match(deps, requested, representative, contexts_by_label):
                result[triple] = representative
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
    """Share compatible definitions when dependencies accept the same context.

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
        context_map maps incoming contexts to idempotent representatives;
        definitions maps representatives to JSON-compatible crate definitions.
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
    groups_by_crate = {}
    node_count = 0
    for fq, target in target_resolutions.items():
        nodes = []
        if target.active:
            nodes.append(struct(context = "", definition = _definition(fq, False, target, target_build_deps, target_build_aliases, exec_triples)))
        for triple in target_triples:
            execution = exec_resolutions_by_target[triple][fq]
            if execution.active:
                nodes.append(struct(context = triple, definition = _definition(fq, True, execution, target_build_deps, target_build_aliases, exec_triples)))
        if not nodes:
            nodes.append(struct(context = "", definition = _definition(fq, False, target, target_build_deps, target_build_aliases, exec_triples)))
        if fq in workspace_crates or fq in preserve_context:
            defined_contexts = set([node.context for node in nodes])
            nodes += [
                struct(context = context, definition = nodes[0].definition)
                for context in contexts
                if context not in defined_contexts and (context or fq in workspace_crates)
            ]
            groups_by_crate[fq] = [[node] for node in nodes]
        else:
            groups_by_crate[fq] = [nodes]
        node_count += len(nodes)

    for _ in range(node_count + 1):
        context_maps = _context_maps(groups_by_crate, contexts)
        contexts_by_label = {dep_label_prefix + fq: mapping for fq, mapping in context_maps.items()}
        refined = {}
        definitions = {}
        changed = False
        for fq, groups in groups_by_crate.items():
            refined[fq] = []
            definitions[fq] = []
            for group in groups:
                new_groups = []
                merged = []
                for node in group:
                    matched = False
                    for index, definition in enumerate(merged):
                        representative = new_groups[index][0].context
                        if not _definitions_compatible(definition, node.definition):
                            continue
                        if not _can_inherit_context(node, representative, contexts_by_label):
                            continue
                        new_groups[index].append(node)
                        _merge_definition(definition, node.definition)
                        matched = True
                        break
                    if not matched:
                        new_groups.append([node])
                        merged.append(_copy_definition(node.definition))
                refined[fq].extend(new_groups)
                definitions[fq].extend(merged)
                changed = changed or len(new_groups) > 1
        if not changed:
            # Compare dependencies before renaming any context. Execution-only
            # crates can then use the default configuration without splitting it.
            default_contexts = {}
            for fq, groups in groups_by_crate.items():
                representative = groups[0][0].context
                if not representative or fq in preserve_context or fq in workspace_crates:
                    continue
                can_clear = True
                for node in groups[0]:
                    if not _can_inherit_context(node, "", contexts_by_label):
                        can_clear = False
                        break
                if can_clear:
                    default_contexts[fq] = representative
            for fq, representative in default_contexts.items():
                context_maps[fq] = {
                    context: "" if value == representative else value
                    for context, value in context_maps[fq].items()
                }
            contexts_by_label = {dep_label_prefix + fq: mapping for fq, mapping in context_maps.items()}
            result = {}
            for fq, groups in groups_by_crate.items():
                crate_definitions = {
                    "" if group[0].context == default_contexts.get(fq) else group[0].context: definition
                    for group, definition in zip(groups, definitions[fq])
                }
                for context, definition in crate_definitions.items():
                    definition["build_contexts"] = {
                        triple: context or triple
                        for triple in definition["build_deps_by_target"]
                    } if fq in preserve_context else _build_contexts(context, definition, contexts, contexts_by_label)
                result[fq] = {
                    "context_map": context_maps[fq],
                    "definitions": crate_definitions,
                    "preserve_context": fq in preserve_context or fq in workspace_crates,
                }
            return result
        groups_by_crate = refined

    fail("Crate configuration refinement did not converge")
