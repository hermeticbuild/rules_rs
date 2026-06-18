load("@bazel_skylib//lib:paths.bzl", "paths")
load("//rs/private:cfg_parser.bzl", "cfg_matches_expr_for_cfg_attrs", "triple_to_cfg_attrs")
load("//rs/private:resolver.bzl", "ensure_host_state", "resolve", "seed_pending_host_features")
load("//rs/private:select_utils.bzl", "compute_select")
load("//rs/private:semver.bzl", "select_matching_version")

def platform_label(triple, use_legacy_rules_rust_platforms):
    if use_legacy_rules_rust_platforms:
        return "@rules_rust//rust/platform:" + triple.replace("-musl", "-gnu").replace("-gnullvm", "-msvc")
    return "@rules_rs//rs/platforms/config:" + triple

def fq_crate(name, version):
    return name + "-" + version

def normalize_path(path):
    return str(path).replace("\\", "/")

def manifest_package_dir(manifest_path, repo_root):
    package_dir = normalize_path(manifest_path).removeprefix(repo_root + "/")
    if package_dir == "Cargo.toml":
        return ""

    return package_dir.removesuffix("/Cargo.toml")

def add_to_dict(d, k, v):
    existing = d.get(k, [])
    if not existing:
        d[k] = existing
    existing.append(v)

def exclude_deps_from_features(features):
    return [f for f in features if not f.startswith("dep:")]

def shared_and_per_platform(platform_items, use_legacy_rules_rust_platforms):
    if not platform_items:
        return [], {}

    by_platform = {}
    for triple, items in platform_items.items():
        platform = platform_label(triple, use_legacy_rules_rust_platforms)
        existing = by_platform.get(platform)
        if existing == None:
            by_platform[platform] = set(items)
        else:
            existing.update(items)

    items, per_platform = compute_select([], by_platform)
    return sorted(items), per_platform

def select_items(items):
    return {k: sorted(v) for k, v in items.items()}

def render_string_list(items):
    return ",\n            ".join(['"%s"' % item for item in sorted(items)])

def cfg_match_info_for_target(target, platform_cfg_attrs, cfg_match_cache):
    match_info = cfg_match_cache.get(target)
    if match_info:
        return match_info

    match_info = cfg_matches_expr_for_cfg_attrs(target, platform_cfg_attrs)
    cfg_match_cache[target] = match_info
    return match_info

def new_feature_resolutions(package_index, possible_deps, possible_features, platform_triples, is_proc_macro = False, is_workspace_member = False):
    return struct(
        features_enabled = {triple: set() for triple in platform_triples},
        build_deps = {triple: set() for triple in platform_triples},
        deps = {triple: set() for triple in platform_triples},
        aliases = {},
        package_index = package_index,
        possible_deps = possible_deps,
        possible_features = possible_features,
        # Feature-world split: fields above are the target world. `host` is a
        # lazily-materialized container (ensure_host_state) the host world fills
        # when it first reaches this crate. Members are world boundaries (see
        # _dep_world in resolver.bzl).
        target_active = {triple: False for triple in platform_triples},
        host = {"state": None},
        is_proc_macro = is_proc_macro,
        is_workspace_member = is_workspace_member,
    )

_INTERNAL_RUSTC_PLACEHOLDER_CRATES = [
    "rustc-std-workspace-alloc",
    "rustc-std-workspace-core",
    "rustc-std-workspace-std",
]

def _is_internal_rustc_placeholder(crate_name):
    return crate_name in _INTERNAL_RUSTC_PLACEHOLDER_CRATES

def cargo_metadata_dep_to_dep_dict(dep):
    rename = dep.get("rename")
    converted = {
        "name": rename or dep["name"],
        "optional": dep.get("optional", False),
        "default_features": dep.get("uses_default_features", True),
        "features": list(dep.get("features", [])),
    }

    req = dep.get("req")
    if req:
        converted["req"] = req

    kind = dep.get("kind")
    if kind and kind != "normal":
        converted["kind"] = kind

    target = dep.get("target")
    if target:
        converted["target"] = target

    if rename:
        converted["package"] = dep["name"]

    return converted

def _cargo_toml_dep_to_dep_dict_inner(dep, spec, is_build = False, target = None):
    if type(spec) == "string":
        converted = {
            "name": dep,
            "req": spec,
        }
    else:
        converted = {
            "name": dep,
            "optional": spec.get("optional", False),
            "default_features": spec.get("default_features", spec.get("default-features", True)),
            "features": spec.get("features", []),
        }
        if "package" in spec:
            converted["package"] = spec["package"]
        if spec.get("version"):
            converted["req"] = spec["version"]

    if is_build:
        converted["kind"] = "build"

    if target:
        converted["target"] = target

    return converted

def cargo_toml_dep_to_dep_dict(dep, spec, package_name, workspace_cargo_toml_json = None, is_build = False, target = None):
    if type(spec) == "dict" and spec.get("workspace") == True:
        workspace = (workspace_cargo_toml_json or {}).get("workspace")
        if not workspace:
            fail("Package %s depends on %s with workspace inheritance, but no workspace section was found" % (package_name, dep))
        if dep not in workspace.get("dependencies", {}):
            fail("Package %s depends on %s with workspace inheritance, but it was not found in workspace.dependencies" % (package_name, dep))

        inherited = _cargo_toml_dep_to_dep_dict_inner(dep, workspace["dependencies"][dep], is_build = is_build, target = target)

        extra_features = spec.get("features")
        if extra_features:
            inherited["features"] = sorted(set(extra_features + inherited.get("features", [])))

        if spec.get("optional"):
            inherited["optional"] = True

        if spec.get("package"):
            inherited["package"] = spec["package"]

        return inherited

    return _cargo_toml_dep_to_dep_dict_inner(dep, spec, is_build = is_build, target = target)

def cargo_toml_dependencies(cargo_toml_json, workspace_cargo_toml_json = None):
    package_name = cargo_toml_json["package"]["name"]
    dependencies = [
        cargo_toml_dep_to_dep_dict(dep, spec, package_name, workspace_cargo_toml_json)
        for dep, spec in cargo_toml_json.get("dependencies", {}).items()
    ] + [
        cargo_toml_dep_to_dep_dict(dep, spec, package_name, workspace_cargo_toml_json, is_build = True)
        for dep, spec in cargo_toml_json.get("build-dependencies", {}).items()
    ]

    for target, value in cargo_toml_json.get("target", {}).items():
        for dep, spec in value.get("dependencies", {}).items():
            dependencies.append(cargo_toml_dep_to_dep_dict(
                dep,
                spec,
                package_name,
                workspace_cargo_toml_json,
                target = target,
            ))

    return dependencies

def cargo_toml_fact(cargo_toml_json, workspace_cargo_toml_json = None, strip_prefix = ""):
    lib = cargo_toml_json.get("lib", {})
    return dict(
        features = cargo_toml_json.get("features", {}),
        dependencies = cargo_toml_dependencies(cargo_toml_json, workspace_cargo_toml_json),
        strip_prefix = strip_prefix,
        # Resolver needs the proc-macro bit at resolution time (split mode) to
        # classify dependency edges.
        is_proc_macro = bool(lib.get("proc-macro") or lib.get("proc_macro")),
    )

def prepare_possible_deps(dependencies, converter = None, skip_internal_rustc_placeholder_crates = True):
    possible_deps = []

    for dep in dependencies:
        if converter:
            dep = converter(dep)
        else:
            dep = dict(dep)

        if dep.get("kind") == "dev":
            continue

        dep_package = dep.get("package") or dep["name"]
        if skip_internal_rustc_placeholder_crates and _is_internal_rustc_placeholder(dep_package):
            continue

        if dep.get("default_features", True):
            add_to_dict(dep, "features", "default")

        possible_deps.append(dep)

    return possible_deps

def _dep_package_name(dep):
    return dep.get("package") or dep["name"]

def compute_package_fq_deps(package, versions_by_name, strict = True):
    possible_dep_fq_crates_by_name = {}

    for maybe_fq_dep in package.get("dependencies", []):
        idx = maybe_fq_dep.find(" ")
        if idx == -1:
            versions = versions_by_name.get(maybe_fq_dep)
            if not versions:
                if strict:
                    fail("Malformed lockfile?")
                continue
            dep = maybe_fq_dep
            resolved_version = versions[0]
        else:
            dep = maybe_fq_dep[:idx]
            resolved_version = maybe_fq_dep[idx + 1:]

        add_to_dict(possible_dep_fq_crates_by_name, dep, fq_crate(dep, resolved_version))

    return possible_dep_fq_crates_by_name

def select_package_fq_dep(dep, fq_deps):
    dep_package = _dep_package_name(dep)
    candidates = fq_deps.get(dep_package)
    if not candidates:
        return None

    if len(candidates) == 1:
        return candidates[0]

    req = dep.get("req")
    if not req:
        return None

    versions = [
        candidate[len(dep_package) + 1:]
        for candidate in candidates
    ]
    version = select_matching_version(req, versions)
    if not version:
        return None

    return fq_crate(dep_package, version)

def compute_workspace_fq_deps(workspace_members, versions_by_name):
    workspace_fq_deps = {}

    for workspace_member in workspace_members:
        fq_deps = compute_package_fq_deps(workspace_member, versions_by_name, strict = False)
        workspace_fq_deps[workspace_member["name"]] = fq_deps

    return workspace_fq_deps

def _relative_to_workspace(path, workspace_root):
    normalized_root = normalize_path(workspace_root)
    normalized_path = normalize_path(path)

    if not paths.is_absolute(normalized_path):
        normalized_path = normalize_path(paths.normalize(paths.join(normalized_root, normalized_path)))

    root_parts = [p for p in normalized_root.split("/") if p]
    path_parts = [p for p in normalized_path.split("/") if p]

    common = 0
    max_common = min(len(root_parts), len(path_parts))
    for idx in range(max_common):
        if root_parts[idx] != path_parts[idx]:
            break
        common = idx + 1

    rel_parts = [".."] * (len(root_parts) - common) + path_parts[common:]
    return "/".join(rel_parts) if rel_parts else "."

def _cargo_metadata_dep_paths_by_name(packages, workspace_root):
    package_dirs = {}

    for package in packages:
        for dep in package.get("dependencies", []):
            dep_path = dep.get("path")
            if not dep_path:
                continue

            package_dirs[dep["name"]] = _relative_to_workspace(dep_path, workspace_root)

    return package_dirs

def _cargo_toml_patch_paths_by_name(workspace_cargo_toml, workspace_root, workspace_package_dir = ""):
    workspace_root = normalize_path(workspace_root)
    workspace_root_prefix = workspace_root + "/"
    package_dirs = {}

    for patches in workspace_cargo_toml.get("patch", {}).values():
        for name, spec in patches.items():
            if type(spec) != "dict":
                continue

            patch_path = spec.get("path")
            if not patch_path:
                continue

            package = spec.get("package") or name
            if paths.is_absolute(patch_path):
                normalized = normalize_path(patch_path)
                if not normalized.startswith(workspace_root_prefix):
                    fail("Patch path for %s points outside the workspace: %s" % (name, patch_path))
                package_dirs[package] = normalized.removeprefix(workspace_root_prefix)
            else:
                package_dirs[package] = normalize_path(paths.normalize(paths.join(workspace_package_dir, patch_path)))

    return package_dirs

def split_lockfile_packages(hub_name, cargo_metadata, workspace_cargo_toml, all_packages, repo_root = None, workspace_package_dir = ""):
    if repo_root == None:
        repo_root = cargo_metadata["workspace_root"]
    repo_root = normalize_path(repo_root)

    workspace_member_keys = {}
    for package in cargo_metadata["packages"]:
        workspace_member_keys[(package["name"], package["version"])] = True

    dep_paths_by_name = _cargo_metadata_dep_paths_by_name(cargo_metadata["packages"], repo_root)
    patch_paths_by_name = _cargo_toml_patch_paths_by_name(workspace_cargo_toml, repo_root, workspace_package_dir)
    workspace_members = []
    packages = []

    for package in all_packages:
        pkg = dict(package)

        if pkg.get("source"):
            packages.append(pkg)
            continue

        key = (pkg["name"], pkg["version"])
        if key in workspace_member_keys:
            workspace_members.append(pkg)
            continue

        rel_path = patch_paths_by_name.get(pkg["name"]) or dep_paths_by_name.get(pkg["name"])
        local_path = rel_path
        if rel_path and not rel_path.startswith("/"):
            local_path = paths.join(repo_root, rel_path)

        if not local_path:
            fail("Found a path dependency on %s %s but could not determine its path from Cargo.toml. Please declare it in [patch] or as a path dependency." % (pkg["name"], pkg["version"]))

        pkg["source"] = "path+" + hub_name + "/" + rel_path
        pkg["local_path"] = local_path
        packages.append(pkg)

    return struct(
        packages = packages,
        workspace_members = workspace_members,
    )

def _package_is_proc_macro(package, package_info):
    # An explicit stamped bit (e.g. proc_macro_packages override) wins; else
    # fall back to `[lib] proc-macro` (path+/git+) or `targets[].kind`.
    is_proc_macro = package.get("is_proc_macro")
    if is_proc_macro != None:
        return bool(is_proc_macro)

    if package_info.get("is_proc_macro"):
        return True

    for target in package_info.get("targets", []):
        if "proc-macro" in target.get("kind", []):
            return True

    return False

def _resolve_packages(packages, package_info_by_fq_crate, platform_triples, dep_converter = None, skip_internal_rustc_placeholder_crates = True):
    feature_resolutions_by_fq_crate = {}
    versions_by_name = {}

    for package_index in range(len(packages)):
        package = packages[package_index]
        name = package["name"]
        version = package["version"]
        fq = fq_crate(name, version)

        add_to_dict(versions_by_name, name, version)

        package_info = package_info_by_fq_crate[fq]
        possible_deps = prepare_possible_deps(
            package_info.get("dependencies", []),
            converter = dep_converter,
            skip_internal_rustc_placeholder_crates = skip_internal_rustc_placeholder_crates,
        )
        feature_resolutions = new_feature_resolutions(
            package_index,
            possible_deps,
            package_info.get("features", {}),
            platform_triples,
            is_proc_macro = _package_is_proc_macro(package, package_info),
        )
        package["feature_resolutions"] = feature_resolutions
        feature_resolutions_by_fq_crate[fq] = feature_resolutions

    return struct(
        feature_resolutions_by_fq_crate = feature_resolutions_by_fq_crate,
        versions_by_name = versions_by_name,
    )

def resolve_package_facts(packages, facts_by_fq_crate, platform_triples, skip_internal_rustc_placeholder_crates = True):
    return _resolve_packages(
        packages,
        facts_by_fq_crate,
        platform_triples,
        skip_internal_rustc_placeholder_crates = skip_internal_rustc_placeholder_crates,
    )

def resolve_cargo_metadata_packages(packages, cargo_metadata, platform_triples, skip_internal_rustc_placeholder_crates = True):
    metadata_by_fq_crate = {
        fq_crate(package["name"], package["version"]): package
        for package in cargo_metadata["packages"]
    }

    return _resolve_packages(
        packages,
        metadata_by_fq_crate,
        platform_triples,
        dep_converter = cargo_metadata_dep_to_dep_dict,
        skip_internal_rustc_placeholder_crates = skip_internal_rustc_placeholder_crates,
    )

def _resolve_possible_deps(
        packages,
        resolver_versions_by_name,
        feature_resolutions_by_fq_crate,
        platform_triples,
        platform_cfg_attrs,
        cfg_match_cache,
        dep_label_prefix):
    for package in packages:
        name = package["name"]
        deps_by_name = {}
        for maybe_fq_dep in package.get("dependencies", []):
            idx = maybe_fq_dep.find(" ")
            if idx != -1:
                dep = maybe_fq_dep[:idx]
                resolved_version = maybe_fq_dep[idx + 1:]
                add_to_dict(deps_by_name, dep, resolved_version)

        for dep in package["feature_resolutions"].possible_deps:
            dep_package = _dep_package_name(dep)

            versions = resolver_versions_by_name.get(dep_package)
            if not versions:
                continue
            constrained_versions = deps_by_name.get(dep_package)
            if constrained_versions:
                versions = constrained_versions

            if len(versions) == 1:
                resolved_version = versions[0]
            else:
                req = dep.get("req")
                if not req:
                    continue

                resolved_version = select_matching_version(req, versions)
                if not resolved_version:
                    if not dep.get("optional"):
                        print("WARNING: %s: could not resolve %s %s among %s" % (name, dep_package, req, versions))
                    continue

            dep_fq = fq_crate(dep_package, resolved_version)
            if dep_fq not in feature_resolutions_by_fq_crate:
                fail("Resolved %s dependency %s but no crate metadata was available" % (name, dep_fq))
            dep["bazel_target"] = "%s%s" % (dep_label_prefix, dep_fq)
            dep["feature_resolutions"] = feature_resolutions_by_fq_crate[dep_fq]

            target = dep.get("target")
            match_info = cfg_match_info_for_target(target, platform_cfg_attrs, cfg_match_cache)
            if match_info.uses_feature_cfg:
                dep["target_expr"] = target
                dep["feature_sensitive"] = True
                dep["target"] = set(platform_triples)
            else:
                dep["target"] = set(match_info.matches)

def _seed_annotation_host_features(feature_resolutions, annotation, platform_triples):
    """Seeds annotation crate_features into the host world WITHOUT activating it.
    Writes live host state if materialized, else pending seeds — so a crate the
    host world never reaches stays unallocated and host-inactive."""
    host = feature_resolutions.host
    state = host["state"]
    if state != None:
        features_enabled = state["features_enabled"]
    else:
        features_enabled = host.get("pending_features")
        if features_enabled == None:
            features_enabled = {triple: set() for triple in platform_triples}
            host["pending_features"] = features_enabled

    if annotation.crate_features:
        for triple in platform_triples:
            features_enabled[triple].update(annotation.crate_features)
    for triple, features in annotation.crate_features_select.items():
        if triple in features_enabled:
            features_enabled[triple].update(features)

def classify_worlds(packages, platform_triples):
    """Classifies each package's host/target feature-world relationship.

    Call after a split-mode resolve() with the packages to classify. Returns
    {fq_crate: class}:

    - "unactivated":     reached by no world/triple (pinned but unused).
    - "target_only":     host world never activated; renders today's content.
    - "host_only":       target never activated; base target carries the host
                         view (no `_host` suffix; includes proc-macros).
    - "identical":       both active, no per-triple difference (disjoint-triple
                         activity included — base renders the merged view).
    - "divergent":       both active and features/deps/build-deps differ at some
                         shared triple; rendering emits a `:<name>_host` target.
    - "label_divergent": not itself divergent, but a host-world dep is, so the
                         host instance's dep LABELS differ; also emits `_host`.

    Divergence propagates along host-world normal-dep edges, dependencies before
    dependents (iterative Kahn; acyclic since dev edges are dropped). Host-only
    crates don't propagate upward (their base already renders the host view).
    """
    feature_resolutions_by_fq = {}
    target_active_by_fq = {}
    host_active_by_fq = {}
    feature_divergent_by_fq = {}

    for package in packages:
        fq = fq_crate(package["name"], package["version"])
        feature_resolutions = package["feature_resolutions"]
        host_state = feature_resolutions.host["state"]

        target_active_any = False
        for is_active in feature_resolutions.target_active.values():
            if is_active:
                target_active_any = True
                break

        host_active_any = False
        if host_state != None:
            for is_active in host_state["active"].values():
                if is_active:
                    host_active_any = True
                    break

        feature_divergent = False
        if target_active_any and host_active_any:
            for triple in platform_triples:
                if not feature_resolutions.target_active[triple] or not host_state["active"][triple]:
                    continue
                if (host_state["features_enabled"][triple] != feature_resolutions.features_enabled[triple] or
                    host_state["deps"][triple] != feature_resolutions.deps[triple] or
                    host_state["build_deps"][triple] != feature_resolutions.build_deps[triple]):
                    feature_divergent = True
                    break

        feature_resolutions_by_fq[fq] = feature_resolutions
        target_active_by_fq[fq] = target_active_any
        host_active_by_fq[fq] = host_active_any
        feature_divergent_by_fq[fq] = feature_divergent

    # Host-world normal-dep edges between classified packages; recover the fq
    # from the label tail. Edges outside the set (e.g. members) can't diverge.
    host_dep_fqs_by_fq = {}
    rdep_fqs_by_fq = {}
    for fq, feature_resolutions in feature_resolutions_by_fq.items():
        host_dep_fqs = []
        host_state = feature_resolutions.host["state"]
        if host_state != None:
            seen = set()
            for triple in platform_triples:
                for label in host_state["deps"][triple]:
                    dep_fq = label[label.rfind(":") + 1:]
                    if dep_fq == fq or dep_fq in seen or dep_fq not in feature_resolutions_by_fq:
                        continue
                    seen.add(dep_fq)
                    host_dep_fqs.append(dep_fq)
        host_dep_fqs_by_fq[fq] = host_dep_fqs
        for dep_fq in host_dep_fqs:
            add_to_dict(rdep_fqs_by_fq, dep_fq, fq)

    # Iterative Kahn pass, dependencies before dependents (cursor drain).
    pending_dep_counts = {}
    ready = []
    for fq, host_dep_fqs in host_dep_fqs_by_fq.items():
        pending_dep_counts[fq] = len(host_dep_fqs)
        if not host_dep_fqs:
            ready.append(fq)

    divergent_by_fq = {}
    for cursor in range(len(feature_resolutions_by_fq)):
        if cursor >= len(ready):
            break
        fq = ready[cursor]

        label_divergent = False
        for dep_fq in host_dep_fqs_by_fq[fq]:
            if divergent_by_fq[dep_fq]:
                label_divergent = True
                break

        divergent_by_fq[fq] = (
            target_active_by_fq[fq] and
            (feature_divergent_by_fq[fq] or (host_active_by_fq[fq] and label_divergent))
        )

        for rdep_fq in rdep_fqs_by_fq.get(fq, []):
            pending_dep_counts[rdep_fq] -= 1
            if pending_dep_counts[rdep_fq] == 0:
                ready.append(rdep_fq)

    if len(divergent_by_fq) != len(feature_resolutions_by_fq):
        fail("rules_rs internal error: cycle detected in the host-world dependency graph during world classification")

    classes_by_fq = {}
    for fq in feature_resolutions_by_fq:
        target_active_any = target_active_by_fq[fq]
        host_active_any = host_active_by_fq[fq]
        if not target_active_any and not host_active_any:
            classes_by_fq[fq] = "unactivated"
        elif target_active_any and not host_active_any:
            classes_by_fq[fq] = "target_only"
        elif host_active_any and not target_active_any:
            classes_by_fq[fq] = "host_only"
        elif feature_divergent_by_fq[fq]:
            classes_by_fq[fq] = "divergent"
        elif divergent_by_fq[fq]:
            classes_by_fq[fq] = "label_divergent"
        else:
            classes_by_fq[fq] = "identical"

    return classes_by_fq

def is_divergent_class(crate_class):
    return crate_class == "divergent" or crate_class == "label_divergent"

def host_rewritten_label(label, classes_by_fq):
    """Rewrites a host-world dep edge's label to the `_host` sibling iff the target crate is divergent."""
    dep_fq = label[label.rfind(":") + 1:]
    if is_divergent_class(classes_by_fq.get(dep_fq)):
        return label + "_host"
    return label

def _host_rewritten_labels(labels, classes_by_fq):
    return set([host_rewritten_label(label, classes_by_fq) for label in labels])

def _host_rewritten_aliases(aliases, classes_by_fq):
    return {host_rewritten_label(label, classes_by_fq): alias for label, alias in aliases.items()}

def _with_rewritten_alias_keys(aliases, classes_by_fq):
    # The base `_bs` consumes both host-rewritten build-dep labels and
    # unrewritten link_deps, so keep the original keys and ADD the rewritten
    # spellings (extra keys are harmless).
    rewritten = dict(aliases)
    for label, alias in aliases.items():
        rewritten_label = host_rewritten_label(label, classes_by_fq)
        if rewritten_label != label:
            rewritten[rewritten_label] = alias
    return rewritten

def render_world_views(feature_resolutions, crate_class, classes_by_fq, platform_triples):
    """Computes the rendered views for one spoke crate under split mode.

    The BASE views are the per-(crate, triple) world merge: target view where
    target-active, else host view where host-active, else the active world's
    view as a fallback (cfg-gated crates may still be CONFIGURED and must stay
    buildable), else empty. Base `deps` are unrewritten on target triples and
    host-rewritten where the host view renders; base `build_deps` are ALWAYS
    host-rewritten (build-dep subtree is host world for both instances).

    Returns a struct:
      crate_features/deps/build_deps: {triple: set} base views.
      aliases: base lib alias dict.
      build_script_aliases: dict or None (None -> rust_crate uses aliases).
      host_crate_features/host_deps/host_build_deps: {triple: set} or None —
          host-instance views, only for divergent/label_divergent crates.
      host_aliases: dict or None.
      unactivated: bool (render the loud incompatible stub).
    """
    host_state = feature_resolutions.host["state"]
    target_active = feature_resolutions.target_active

    target_active_anywhere = False
    for is_active in target_active.values():
        if is_active:
            target_active_anywhere = True
            break

    host_active_anywhere = False
    if host_state != None:
        for is_active in host_state["active"].values():
            if is_active:
                host_active_anywhere = True
                break

    base_features = {}
    base_deps = {}
    base_build_deps = {}
    base_aliases = {}
    merged_host_view = False
    merged_target_view = False
    for triple in platform_triples:
        # Per-triple merge. Priority: this triple's target world, else its host
        # world, else the target fallback (active at another triple), else the
        # host fallback, else empty. The fallback keeps cfg-gated crates that
        # are merely CONFIGURED (public hub aliases, hand-written refs)
        # buildable instead of silently empty.
        host_active_here = host_state != None and host_state["active"][triple]
        if target_active[triple] or (not host_active_here and target_active_anywhere):
            merged_target_view = True
            base_features[triple] = feature_resolutions.features_enabled[triple]
            base_deps[triple] = feature_resolutions.deps[triple]
            base_build_deps[triple] = _host_rewritten_labels(feature_resolutions.build_deps[triple], classes_by_fq)
        elif host_active_here or host_active_anywhere:
            merged_host_view = True
            base_features[triple] = host_state["features_enabled"][triple]
            base_deps[triple] = _host_rewritten_labels(host_state["deps"][triple], classes_by_fq)
            base_build_deps[triple] = _host_rewritten_labels(host_state["build_deps"][triple], classes_by_fq)
        else:
            base_features[triple] = set()
            base_deps[triple] = set()
            base_build_deps[triple] = set()

    if merged_target_view:
        base_aliases |= feature_resolutions.aliases
    if merged_host_view:
        base_aliases |= _host_rewritten_aliases(host_state["aliases"], classes_by_fq)

    build_script_aliases = _with_rewritten_alias_keys(base_aliases, classes_by_fq)
    if build_script_aliases == base_aliases:
        build_script_aliases = None

    host_crate_features = None
    host_deps = None
    host_build_deps = None
    host_aliases = None
    if is_divergent_class(crate_class):
        host_crate_features = {}
        host_deps = {}
        host_build_deps = {}
        for triple in platform_triples:
            if host_state["active"][triple]:
                host_crate_features[triple] = host_state["features_enabled"][triple]
                host_deps[triple] = _host_rewritten_labels(host_state["deps"][triple], classes_by_fq)
                host_build_deps[triple] = _host_rewritten_labels(host_state["build_deps"][triple], classes_by_fq)
            else:
                host_crate_features[triple] = set()
                host_deps[triple] = set()
                host_build_deps[triple] = set()
        host_aliases = _host_rewritten_aliases(host_state["aliases"], classes_by_fq)

    return struct(
        crate_features = base_features,
        deps = base_deps,
        build_deps = base_build_deps,
        aliases = base_aliases,
        build_script_aliases = build_script_aliases,
        host_crate_features = host_crate_features,
        host_deps = host_deps,
        host_build_deps = host_build_deps,
        host_aliases = host_aliases,
        unactivated = crate_class == "unactivated",
    )

def resolve_cargo_workspace_members(
        ctx,
        *,
        cargo_metadata,
        packages,
        workspace_members,
        versions_by_name,
        feature_resolutions_by_fq_crate,
        annotations,
        platform_triples,
        materialize_workspace_members,
        validate_lockfile = True,
        debug = False,
        dep_label_prefix = "//:",
        skip_internal_rustc_placeholder_crates = True,
        watch_manifests = False,
        use_legacy_rules_rust_platforms = False):
    platform_cfg_attrs = [triple_to_cfg_attrs(triple) for triple in platform_triples]
    platform_cfg_attrs_by_triple = {}
    for cfg_attr in platform_cfg_attrs:
        platform_cfg_attrs_by_triple[cfg_attr["_triple"]] = cfg_attr

    cfg_match_cache = {None: struct(matches = platform_triples, uses_feature_cfg = False)}

    workspace_member_keys = {}
    for package in cargo_metadata["packages"]:
        workspace_member_keys[(package["name"], package["version"])] = True

    resolver_versions_by_name = {name: versions[:] for name, versions in versions_by_name.items()}
    workspace_members_by_key = {(package["name"], package["version"]): package for package in workspace_members}
    resolver_packages = packages[:]
    for package in cargo_metadata["packages"]:
        name = package["name"]
        version = package["version"]

        versions = resolver_versions_by_name.get(name, [])
        if version not in versions:
            if versions:
                versions.append(version)
            else:
                resolver_versions_by_name[name] = [version]

        possible_features = package.get("features", {})
        possible_deps = prepare_possible_deps(
            package.get("dependencies", []),
            converter = cargo_metadata_dep_to_dep_dict,
            skip_internal_rustc_placeholder_crates = skip_internal_rustc_placeholder_crates,
        )

        package_index = len(resolver_packages)
        lockfile_pkg = workspace_members_by_key.get((name, version), {})
        resolver_package = {
            "name": name,
            "version": version,
            "dependencies": lockfile_pkg.get("dependencies", []),
        }

        # Proc-macro bit from `cargo metadata`; split treats proc-macro members
        # as host-world roots.
        member_is_proc_macro = False
        for target in package.get("targets", []):
            if "proc-macro" in target.get("kind", []):
                member_is_proc_macro = True
                break

        feature_resolutions = new_feature_resolutions(
            package_index,
            possible_deps,
            possible_features,
            platform_triples,
            is_proc_macro = member_is_proc_macro,
            is_workspace_member = True,
        )
        resolver_package["feature_resolutions"] = feature_resolutions
        feature_resolutions_by_fq_crate[fq_crate(name, version)] = feature_resolutions

        resolver_packages.append(resolver_package)

    _resolve_possible_deps(
        resolver_packages,
        resolver_versions_by_name,
        feature_resolutions_by_fq_crate,
        platform_triples,
        platform_cfg_attrs,
        cfg_match_cache,
        dep_label_prefix,
    )

    workspace_fq_deps = compute_workspace_fq_deps(workspace_members, resolver_versions_by_name)
    workspace_dep_versions_by_name = {}
    workspace_dep_labels_by_triple = {triple: set() for triple in platform_triples}

    for package in cargo_metadata["packages"]:
        if watch_manifests:
            ctx.watch(package["manifest_path"])

        package_feature_resolutions = feature_resolutions_by_fq_crate[fq_crate(package["name"], package["version"])]

        # Members are world boundaries: always target-world roots (single
        # gazelle targets must link base instances everywhere). Only edges to
        # proc-macro SPOKES cross into the host world during seeding.
        for triple in platform_triples:
            package_feature_resolutions.target_active[triple] = True

        if "default" in package.get("features", {}):
            for triple in platform_triples:
                package_feature_resolutions.features_enabled[triple].add("default")

        fq_deps = workspace_fq_deps.get(package["name"], {})

        for dep in package["dependencies"]:
            source = dep.get("source")
            dep_name = dep["name"]
            dep_package = _dep_package_name(dep)
            dep_fq = select_package_fq_dep(dep, fq_deps)
            dep_version = None
            if dep_fq:
                dep_version = dep_fq[len(dep_package) + 1:]
            is_first_party_dep = not source and dep_version and (dep_package, dep_version) in workspace_member_keys

            if validate_lockfile and source and source.startswith("registry+"):
                req = dep["req"]
                fq = dep_fq
                if req and fq:
                    locked_version = fq[len(dep_package) + 1:]
                    if not select_matching_version(req, [locked_version]):
                        fail(("ERROR: Cargo.lock out of sync: %s requires %s %s but Cargo.lock has %s.\n\n" +
                              "If this is incorrect, please set `validate_lockfile = False` in `crate.from_cargo`\n" +
                              "and file a bug at https://github.com/hermeticbuild/rules_rs/issues/new") % (
                            package["name"],
                            dep_package,
                            req,
                            locked_version,
                        ))

            features = list(dep.get("features", []))
            if dep.get("uses_default_features"):
                features.append("default")

            if not dep_fq:
                continue

            if dep_fq not in feature_resolutions_by_fq_crate:
                fail("Resolved %s dependency %s but no crate metadata was available" % (package["name"], dep_fq))

            if not is_first_party_dep or materialize_workspace_members:
                dep["bazel_target"] = "%s%s" % (dep_label_prefix, dep_fq)

            feature_resolutions = feature_resolutions_by_fq_crate[dep_fq]

            if not is_first_party_dep or materialize_workspace_members:
                versions = workspace_dep_versions_by_name.get(dep_name)
                if not versions:
                    versions = set()
                    workspace_dep_versions_by_name[dep_name] = versions
                versions.add(dep_fq)

            target = dep.get("target")
            match_info = cfg_match_info_for_target(target, platform_cfg_attrs, cfg_match_cache)

            # Member edges cross to host only for proc-macro SPOKES (host-only,
            # so the base label is world-consistent). Build/dev edges stay
            # target-world.
            seed_host = feature_resolutions.is_proc_macro and not feature_resolutions.is_workspace_member

            for triple in match_info.matches:
                if not is_first_party_dep or materialize_workspace_members:
                    workspace_dep_labels_by_triple[triple].add(":" + dep_name)
                if seed_host:
                    dep_host_state = ensure_host_state(feature_resolutions)
                    dep_host_state["features_enabled"][triple].update(features)
                    dep_host_state["active"][triple] = True
                else:
                    feature_resolutions.features_enabled[triple].update(features)
                    feature_resolutions.target_active[triple] = True

                    # Member [build-dependencies] are feature-AMPHIBIOUS:
                    # edge stays target-world, but features also reach the
                    # dep's host instance (without activating it) so shared
                    # crates agree across worlds.
                    if dep.get("kind") == "build" and not feature_resolutions.is_workspace_member:
                        seed_pending_host_features(feature_resolutions, triple, features)

    for crate, annotation_versions in annotations.items():
        for version_key, annotation in annotation_versions.items():
            target_versions = resolver_versions_by_name.get(crate, [])
            if version_key != "*":
                if version_key not in target_versions:
                    continue
                target_versions = [version_key]
            if not annotation.crate_features and not annotation.crate_features_select:
                continue
            for version in target_versions:
                annotated_feature_resolutions = feature_resolutions_by_fq_crate[fq_crate(crate, version)]
                features_enabled = annotated_feature_resolutions.features_enabled
                if annotation.crate_features:
                    for triple in platform_triples:
                        features_enabled[triple].update(annotation.crate_features)
                for triple, features in annotation.crate_features_select.items():
                    if triple in features_enabled:
                        features_enabled[triple].update(features)
                _seed_annotation_host_features(annotated_feature_resolutions, annotation, platform_triples)

    resolution_rounds = resolve(ctx, resolver_packages, feature_resolutions_by_fq_crate, platform_cfg_attrs_by_triple, debug)

    for package in packages:
        feature_resolutions = package["feature_resolutions"]
        features_enabled = feature_resolutions.features_enabled
        host_state = feature_resolutions.host["state"]

        for dep in feature_resolutions.possible_deps:
            if "bazel_target" in dep:
                continue

            prefixed_dep_alias = "dep:" + dep["name"]

            for triple in platform_triples:
                if prefixed_dep_alias in features_enabled[triple]:
                    fail("Crate %s has enabled %s but it was not in the lockfile..." % (package["name"], prefixed_dep_alias))
                if host_state != None and prefixed_dep_alias in host_state["features_enabled"][triple]:
                    fail("Crate %s has enabled %s in the host world but it was not in the lockfile..." % (package["name"], prefixed_dep_alias))

    return struct(
        resolution_rounds = resolution_rounds,
        cfg_match_cache = cfg_match_cache,
        feature_resolutions_by_fq_crate = feature_resolutions_by_fq_crate,
        platform_cfg_attrs = platform_cfg_attrs,
        platform_cfg_attrs_by_triple = platform_cfg_attrs_by_triple,
        resolver_versions_by_name = resolver_versions_by_name,
        workspace_dep_labels_by_triple = workspace_dep_labels_by_triple,
        workspace_dep_versions_by_name = workspace_dep_versions_by_name,
        workspace_fq_deps = workspace_fq_deps,
        workspace_member_keys = workspace_member_keys,
    )

def workspace_dep_data(
        *,
        cargo_metadata,
        feature_resolutions_by_fq_crate,
        platform_triples,
        platform_cfg_attrs,
        cfg_match_cache,
        repo_root,
        workspace_package,
        use_legacy_rules_rust_platforms):
    # Members are world boundaries, so DEP_DATA always renders the target-world
    # view with unrewritten labels (no `_host` label may reach it).
    dep_data = {}
    for package in cargo_metadata["packages"]:
        aliases = {}
        crate_features = {triple: set() for triple in platform_triples}
        deps = {triple: set() for triple in platform_triples}
        build_deps = {triple: set() for triple in platform_triples}
        dev_deps = {triple: set() for triple in platform_triples}
        package_dir = manifest_package_dir(package["manifest_path"], repo_root)
        package_manifest_dir = normalize_path(package["manifest_path"]).removesuffix("/Cargo.toml")
        binaries = {}
        shared_libraries = {}
        feature_resolutions = feature_resolutions_by_fq_crate.get(fq_crate(package["name"], package["version"]))

        for target in package.get("targets", []):
            kinds = target.get("kind", [])
            if "cdylib" not in kinds and "bin" not in kinds:
                continue

            src_path = target.get("src_path")
            if not src_path:
                continue

            entrypoint = normalize_path(src_path).removeprefix(repo_root + "/")
            if package_dir and entrypoint.startswith(package_dir + "/"):
                entrypoint = entrypoint.removeprefix(package_dir + "/")

            if "cdylib" in kinds:
                shared_libraries[target["name"]] = entrypoint
            elif "bin" in kinds:
                binaries[target["name"]] = entrypoint

        for dep in package["dependencies"]:
            bazel_target = dep.get("bazel_target")
            dep_path = dep.get("path")
            if not bazel_target:
                if not dep_path:
                    continue
                bazel_target = "//" + paths.join(workspace_package, normalize_path(dep_path).removeprefix(repo_root + "/"))

            kind = dep["kind"]

            is_self_dep = dep_path and normalize_path(dep_path) == package_manifest_dir

            if not is_self_dep:
                if dep.get("rename"):
                    aliases[bazel_target] = dep["rename"].replace("-", "_")
                elif dep_path:
                    aliases[bazel_target] = dep["name"].replace("-", "_")

            target = dep.get("target")
            match_info = cfg_match_info_for_target(target, platform_cfg_attrs, cfg_match_cache)
            match = match_info.matches

            if kind == "dev":
                target_deps = dev_deps
            elif kind == "build":
                target_deps = build_deps
            else:
                target_deps = deps

            for triple in match:
                if dep.get("optional") and feature_resolutions:
                    dep_name = dep.get("rename") or dep["name"]
                    triple_features = feature_resolutions.features_enabled[triple]
                    if dep_name not in triple_features and ("dep:" + dep_name) not in triple_features:
                        continue

                if is_self_dep:
                    continue

                target_deps[triple].add(bazel_target)

        if feature_resolutions:
            for triple in platform_triples:
                crate_features[triple].update(exclude_deps_from_features(feature_resolutions.features_enabled[triple]))

        bazel_package = paths.join(workspace_package, package_dir) if package_dir else workspace_package

        crate_features, crate_features_by_platform = shared_and_per_platform(crate_features, use_legacy_rules_rust_platforms)
        deps, deps_by_platform = shared_and_per_platform(deps, use_legacy_rules_rust_platforms)
        build_deps, build_deps_by_platform = shared_and_per_platform(build_deps, use_legacy_rules_rust_platforms)
        dev_deps, dev_deps_by_platform = shared_and_per_platform(dev_deps, use_legacy_rules_rust_platforms)

        dep_data[bazel_package] = {
            "aliases": aliases,
            "binaries": binaries,
            "build_deps": build_deps,
            "build_deps_by_platform": build_deps_by_platform,
            "crate_features": crate_features,
            "crate_features_by_platform": crate_features_by_platform,
            "deps": deps,
            "deps_by_platform": deps_by_platform,
            "dev_deps": dev_deps,
            "dev_deps_by_platform": dev_deps_by_platform,
            "shared_libraries": shared_libraries,
        }

    return dep_data

def render_dep_data(dep_data):
    return "DEP_DATA = {\n%s\n}\n\n" % "\n".join([
        "    %s: %s," % (repr(package), repr(dep_data[package]))
        for package in sorted(dep_data.keys())
    ])
