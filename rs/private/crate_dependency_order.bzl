"""Crate dependency order."""

def hub_dep_fq(label, hub_name):
    prefix = "@%s//:" % hub_name
    if label.startswith(prefix):
        return label.removeprefix(prefix)
    return None

def packages_in_dependency_order(packages, feature_resolutions_by_fq_crate, hub_name):
    """Orders packages with a deterministic Kahn topological sort."""
    package_by_fq = {}
    duplicate_fqs = {}
    for package in packages:
        fq = "%s-%s" % (package["name"], package["version"])
        if fq in package_by_fq:
            duplicate_fqs[fq] = True
        package_by_fq[fq] = package

    if duplicate_fqs:
        fail("Cargo package graph for hub %s contains multiple packages with the same name and version: %s" % (
            hub_name,
            sorted(duplicate_fqs),
        ))

    dependency_count_by_fq = {}
    dependents_by_fq = {fq: {} for fq in package_by_fq}

    # Build each package's unique in-hub dependency set once. The same edge can
    # appear under multiple platform triples, so it must only contribute one to
    # the unresolved-dependency count.
    for fq in sorted(package_by_fq):
        dependencies = {}
        feature_resolutions = feature_resolutions_by_fq_crate[fq]
        for deps_by_triple in [feature_resolutions.deps, feature_resolutions.build_deps]:
            for deps in deps_by_triple.values():
                for label in deps:
                    dep_fq = hub_dep_fq(label, hub_name)
                    if dep_fq in package_by_fq:
                        dependencies[dep_fq] = True

        dependency_count_by_fq[fq] = len(dependencies)
        for dep_fq in dependencies:
            dependents_by_fq[dep_fq][fq] = True

    ready = sorted([
        fq
        for fq, dependency_count in dependency_count_by_fq.items()
        if dependency_count == 0
    ])
    ordered = []

    # Starlark has no while loop, so use a bounded number of frontier rounds.
    # Every non-empty round emits at least one package.
    for _ in range(len(packages)):
        if not ready:
            break
        next_ready = []
        for fq in ready:
            ordered.append(package_by_fq[fq])
            for dependent_fq in dependents_by_fq[fq]:
                dependency_count_by_fq[dependent_fq] -= 1
                if dependency_count_by_fq[dependent_fq] == 0:
                    next_ready.append(dependent_fq)
        ready = sorted(next_ready)

    if len(ordered) != len(packages):
        pending = sorted([
            fq
            for fq, dependency_count in dependency_count_by_fq.items()
            if dependency_count != 0
        ])
        fail("Cargo package graph for hub %s contains a dependency cycle among %s" % (
            hub_name,
            pending,
        ))

    return ordered
