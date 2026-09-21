"""Choose explicit dependency labels for target and build feature resolutions."""

def _maps_conflict(target_values, exec_values):
    for key, value in exec_values.items():
        if key in target_values and target_values[key] != value:
            return True
    return False

def _features_by_platform(resolution):
    return {
        triple: set([feature for feature in features if not feature.startswith("dep:")])
        for triple, features in resolution.features_enabled.items()
    }

def _deps_by_platform(deps, exec_labels):
    return {
        triple: set([exec_labels.get(dep, dep) for dep in labels])
        for triple, labels in deps.items()
    }

def _aliases_for_deps(aliases, deps, exec_labels):
    labels = set([dep for labels in deps.values() for dep in labels])
    return {
        exec_labels.get(dep, dep): alias
        for dep, alias in aliases.items()
        if dep in labels
    }

def _needs_split(target_resolution, exec_resolution, exec_labels):
    if _maps_conflict(_features_by_platform(target_resolution), _features_by_platform(exec_resolution)):
        return True
    if _maps_conflict(target_resolution.deps, _deps_by_platform(exec_resolution.deps, exec_labels)):
        return True
    if _maps_conflict(
        _deps_by_platform(target_resolution.build_deps, exec_labels),
        _deps_by_platform(exec_resolution.build_deps, exec_labels),
    ):
        return True
    if _maps_conflict(
        _aliases_for_deps(target_resolution.aliases, target_resolution.deps, {}),
        _aliases_for_deps(exec_resolution.aliases, exec_resolution.deps, exec_labels),
    ):
        return True
    return _maps_conflict(
        _aliases_for_deps(target_resolution.aliases, target_resolution.build_deps, exec_labels),
        _aliases_for_deps(exec_resolution.aliases, exec_resolution.build_deps, exec_labels),
    )

def prepare_exec_dependency_labels(target_resolutions, exec_resolutions, dep_label_prefix):
    """Return split crate names and their explicit execution dependency labels.

    The input resolutions are not modified. A crate with one active resolution,
    or two resolutions that can share one definition, retains its ordinary label.
    Splitting a normal dependency can require splitting its parents even when
    their own features match. Both definitions already use execution labels for
    build dependencies, so splitting a build dependency does not propagate.

    Args:
        target_resolutions: Map of fully qualified crate names to target resolutions.
        exec_resolutions: Map of fully qualified crate names to execution resolutions.
        dep_label_prefix: Prefix used by dependency labels, such as "@crates//:".

    Returns:
        A struct with split_crates, a set of fully qualified crate names, and
        exec_labels, a map from ordinary dependency labels to execution labels.
    """
    split_crates = set()
    exec_labels = {}
    candidates = {
        fq: resolution
        for fq, resolution in target_resolutions.items()
        if resolution.active and fq in exec_resolutions and exec_resolutions[fq].active
    }
    parents_by_dep = {}
    for fq in candidates:
        for labels in exec_resolutions[fq].deps.values():
            for dep in labels:
                parents_by_dep.setdefault(dep, set()).add(fq)

    pending = set(candidates)
    for _ in range(len(candidates) + 1):
        next_pending = set()
        for fq in pending:
            if fq in split_crates or not _needs_split(candidates[fq], exec_resolutions[fq], exec_labels):
                continue
            split_crates.add(fq)
            dep_label = dep_label_prefix + fq
            exec_labels[dep_label] = dep_label_prefix + "__exec/" + fq
            next_pending.update(parents_by_dep.get(dep_label, []))
        if not next_pending:
            break
        pending = next_pending

    return struct(split_crates = split_crates, exec_labels = exec_labels)
