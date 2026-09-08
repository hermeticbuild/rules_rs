"""Crate collection order."""

load("//rs/private:annotations.bzl", "annotation_for")
load("//rs/private:cargo_workspace_graph.bzl", _fq_crate = "fq_crate")
load("//rs/private:crate_dependency_order.bzl", _hub_dep_fq = "hub_dep_fq")
load("//rs/private:crate_hub_generation.bzl", _git_crate_package_path = "git_crate_package_path")
load("//rs/private:crate_identity.bzl", _crate_identity = "crate_identity")

def _coalescer_node_key(plan, package):
    """Returns a cross-hub node key for collection ordering."""
    hub_name = plan["hub_name"]
    source = package["source"]
    if source.startswith("path+"):
        return json.encode(["hub-local", hub_name, _fq_crate(package["name"], package["version"])])

    package_path = ""
    if source.startswith("git+"):
        annotation = annotation_for(
            plan["annotations"],
            package["name"],
            package["version"],
            hub_name,
        )
        package_path = _git_crate_package_path(annotation, package.get("strip_prefix"))
    identity = _crate_identity(package, package_path)
    if identity == None:
        fail("Missing crate identity for %s %s" % (package["name"], package["version"]))
    return json.encode(["crate", identity])

def coalescer_collection_order(resolved_configs):
    """Orders identity groups after the union of their cross-hub dependencies."""
    nodes = {}
    node_by_occurrence = {}

    for resolved in resolved_configs:
        plan = resolved["plan"]
        hub_name = plan["hub_name"]
        for package in plan["packages"]:
            fq = _fq_crate(package["name"], package["version"])
            node_key = _coalescer_node_key(plan, package)
            node = nodes.get(node_key)
            if node == None:
                node = {
                    "dependencies": {},
                    "dependents": {},
                    "occurrences": [],
                }
                nodes[node_key] = node
            node["occurrences"].append({
                "package": package,
                "plan": plan,
            })
            node_by_occurrence[json.encode([hub_name, fq])] = node_key

    # A dependency enabled in any occurrence orders the dependency identity
    # before every occurrence of the parent identity. This is stronger than a
    # per-hub topological order: optional features can make a crate a leaf in
    # one hub and a parent in another.
    for node_key, node in nodes.items():
        for occurrence in node["occurrences"]:
            plan = occurrence["plan"]
            package = occurrence["package"]
            hub_name = plan["hub_name"]
            fq = _fq_crate(package["name"], package["version"])
            feature_resolutions = plan["feature_resolutions_by_fq_crate"][fq]
            for deps_by_triple in [feature_resolutions.deps, feature_resolutions.build_deps]:
                for labels in deps_by_triple.values():
                    for label in labels:
                        dep_fq = _hub_dep_fq(label, hub_name)
                        dep_node_key = node_by_occurrence.get(json.encode([hub_name, dep_fq]))
                        if dep_node_key != None and dep_node_key != node_key:
                            node["dependencies"][dep_node_key] = True

    dependency_count = {}
    for node_key, node in nodes.items():
        dependency_count[node_key] = len(node["dependencies"])
        for dep_node_key in node["dependencies"]:
            nodes[dep_node_key]["dependents"][node_key] = True

    ready = sorted([
        node_key
        for node_key, count in dependency_count.items()
        if count == 0
    ])
    ordered = []
    for _ in range(len(nodes)):
        if not ready:
            break
        next_ready = []
        for node_key in ready:
            ordered.extend(nodes[node_key]["occurrences"])
            for dependent_node_key in nodes[node_key]["dependents"]:
                dependency_count[dependent_node_key] -= 1
                if dependency_count[dependent_node_key] == 0:
                    next_ready.append(dependent_node_key)
        ready = sorted(next_ready)

    if len(ordered) != len(node_by_occurrence):
        pending = sorted([
            node_key
            for node_key, count in dependency_count.items()
            if count != 0
        ])
        fail("Combined Cargo package graphs contain a dependency cycle among identities %s" % pending)
    return ordered

_coalescer_collection_order = coalescer_collection_order
