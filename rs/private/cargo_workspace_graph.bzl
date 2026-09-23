load("@bazel_skylib//lib:paths.bzl", "paths")
load("//rs/private:cfg_parser.bzl", "cfg_matches_expr_for_cfg_attrs", "triple_to_cfg_attrs")
load("//rs/private:resolver.bzl", "collect_exec_build_dependencies", "resolve")
load("//rs/private:select_utils.bzl", "shared_and_per_platform")
load("//rs/private:semver.bzl", "select_matching_version")

def fq_crate(name, version):
    return name + "-" + version

def normalize_path(path):
    return str(path).replace("\\", "/")

def manifest_package_dir(manifest_path, repo_root):
    package_dir = normalize_path(manifest_path).removeprefix(repo_root + "/")
    if package_dir == "Cargo.toml":
        return ""

    return package_dir.removesuffix("/Cargo.toml")

def cfg_match_info_for_target(target, platform_cfg_attrs, cfg_match_cache):
    match_info = cfg_match_cache.get(target)
    if match_info:
        return match_info

    match_info = cfg_matches_expr_for_cfg_attrs(target, platform_cfg_attrs)
    cfg_match_cache[target] = match_info
    return match_info

def new_feature_resolutions(package_index, possible_deps, possible_features, platform_triples):
    return struct(
        active = set(),
        features_enabled = {platform_triple: set() for platform_triple in platform_triples},
        # Values are explicit Cargo aliases, or None for the library's crate name.
        build_deps = {platform_triple: {} for platform_triple in platform_triples},
        deps = {platform_triple: {} for platform_triple in platform_triples},
        package_index = package_index,
        possible_deps = possible_deps,
        possible_features = possible_features,
    )

_INTERNAL_RUSTC_PLACEHOLDER_CRATES = [
    "rustc-std-workspace-alloc",
    "rustc-std-workspace-core",
    "rustc-std-workspace-std",
]

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
    return dict(
        features = cargo_toml_json.get("features", {}),
        dependencies = cargo_toml_dependencies(cargo_toml_json, workspace_cargo_toml_json),
        strip_prefix = strip_prefix,
        bazel_deps = cargo_toml_json.get("package", {}).get("metadata", {}).get("bazel", {}).get("deps", []),
    )

def prepare_possible_deps(dependencies, converter = None, skip_internal_rustc_placeholder_crates = True):
    possible_deps = []

    for dep in dependencies:
        if dep.get("kind") == "dev":
            continue

        dep_package = dep.get("package") or dep["name"]
        if skip_internal_rustc_placeholder_crates and dep_package in _INTERNAL_RUSTC_PLACEHOLDER_CRATES:
            continue

        if converter:
            dep = converter(dep)
        else:
            dep = dict(dep)

        if dep.get("default_features", True):
            dep.setdefault("features", []).append("default")

        possible_deps.append(dep)

    return possible_deps

def _dep_package_name(dep):
    return dep.get("package") or dep["name"]

def compute_package_fq_deps(package, versions_by_name):
    possible_dep_fq_crates_by_name = {}

    for maybe_fq_dep in package.get("dependencies", []):
        idx = maybe_fq_dep.find(" ")
        if idx == -1:
            versions = versions_by_name.get(maybe_fq_dep)
            if not versions:
                continue
            dep = maybe_fq_dep
            resolved_version = versions[0]
        else:
            dep = maybe_fq_dep[:idx]
            resolved_version = maybe_fq_dep[idx + 1:]

        possible_dep_fq_crates_by_name.setdefault(dep, []).append(fq_crate(dep, resolved_version))

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

    workspace_member_keys = set()
    for package in cargo_metadata["packages"]:
        workspace_member_keys.add((package["name"], package["version"]))

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

def resolve_packages(packages, package_info_by_fq_crate, platform_triples, dep_converter = None, skip_internal_rustc_placeholder_crates = True):
    feature_resolutions_by_fq_crate = {}
    versions_by_name = {}

    for package_index in range(len(packages)):
        package = packages[package_index]
        name = package["name"]
        version = package["version"]
        fq = fq_crate(name, version)

        versions_by_name.setdefault(name, []).append(version)

        package_info = package_info_by_fq_crate[fq]
        possible_deps = prepare_possible_deps(
            package_info.get("dependencies", []),
            converter = dep_converter,
            skip_internal_rustc_placeholder_crates = skip_internal_rustc_placeholder_crates,
        )
        feature_resolutions = new_feature_resolutions(package_index, possible_deps, package_info.get("features", {}), platform_triples)
        package["feature_resolutions"] = feature_resolutions
        feature_resolutions_by_fq_crate[fq] = feature_resolutions

    return struct(
        feature_resolutions_by_fq_crate = feature_resolutions_by_fq_crate,
        versions_by_name = versions_by_name,
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
                deps_by_name.setdefault(dep, []).append(resolved_version)

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
            dep["package_index"] = feature_resolutions_by_fq_crate[dep_fq].package_index

            target = dep.get("target")
            match_info = cfg_match_info_for_target(target, platform_cfg_attrs, cfg_match_cache)
            if match_info.uses_feature_cfg:
                dep["target_expr"] = target
                dep["target"] = set(platform_triples)
            else:
                dep["target"] = set(match_info.matches)

def _apply_annotation_features(feature_resolutions, annotation):
    for platform_triple, features in feature_resolutions.features_enabled.items():
        features.update(annotation.crate_features)
        features.update(annotation.crate_features_select.get(platform_triple, []))

def _copy_resolutions(template_packages, platform_triples):
    packages = []
    resolutions = {}
    for package in template_packages:
        template = package["feature_resolutions"]
        resolution = new_feature_resolutions(
            template.package_index,
            [dict(dep) for dep in template.possible_deps],
            template.possible_features,
            platform_triples,
        )
        for platform_triple in platform_triples:
            resolution.features_enabled[platform_triple].update(template.features_enabled.get(platform_triple, []))
        resolutions[fq_crate(package["name"], package["version"])] = resolution
        packages.append(dict(package, feature_resolutions = resolution))

    return packages, resolutions

def _resolve_exec_targets(ctx, target_packages, template_packages, cargo_target_triples, exec_cfg_attrs_by_triple, debug):
    exec_resolutions_by_cargo_target_triple = {}
    resolved_seeds = {}

    for cargo_target_triple in cargo_target_triples:
        seeds = collect_exec_build_dependencies(target_packages, template_packages, exec_cfg_attrs_by_triple, cargo_target_triple)
        seed_key = tuple([
            (index, exec_platform_triple, tuple(sorted(features)))
            for (index, exec_platform_triple), features in sorted(seeds.features.items())
        ])
        if seed_key not in resolved_seeds:
            exec_packages, exec_resolutions = _copy_resolutions(template_packages, exec_cfg_attrs_by_triple)
            for (index, exec_platform_triple), features in seeds.features.items():
                resolution = exec_packages[index]["feature_resolutions"]
                resolution.active.add(exec_platform_triple)
                resolution.features_enabled[exec_platform_triple].update(features)
            resolve(ctx, exec_packages, exec_cfg_attrs_by_triple, debug, restrict_to_active_platforms = True)
            resolved_seeds[seed_key] = exec_resolutions
        exec_resolutions_by_cargo_target_triple[cargo_target_triple] = struct(
            resolutions = resolved_seeds[seed_key],
            build_deps = seeds.build_deps,
        )

    return exec_resolutions_by_cargo_target_triple

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
        exec_platform_triples = [],
        validate_lockfile = True,
        debug = False,
        dep_label_prefix = "//:",
        skip_internal_rustc_placeholder_crates = True,
        watch_manifests = False):
    platform_cfg_attrs = [triple_to_cfg_attrs(platform_triple) for platform_triple in platform_triples]
    platform_cfg_attrs_by_triple = {cfg_attr["_triple"]: cfg_attr for cfg_attr in platform_cfg_attrs}

    cfg_match_cache = {None: struct(matches = platform_triples, uses_feature_cfg = False)}

    exec_platform_cfg_attrs_by_triple = {exec_platform_triple: triple_to_cfg_attrs(exec_platform_triple) for exec_platform_triple in exec_platform_triples}

    resolver_versions_by_name = {name: versions[:] for name, versions in versions_by_name.items()}
    workspace_members_by_key = {(package["name"], package["version"]): package for package in workspace_members}
    resolver_packages = packages[:]
    for package in cargo_metadata["packages"]:
        name = package["name"]
        version = package["version"]
        versions = resolver_versions_by_name.setdefault(name, [])
        if version not in versions:
            versions.append(version)

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

        feature_resolutions = new_feature_resolutions(package_index, possible_deps, possible_features, platform_triples)
        resolver_package["feature_resolutions"] = feature_resolutions
        feature_resolutions_by_fq_crate[fq_crate(name, version)] = feature_resolutions

        resolver_packages.append(resolver_package)

    exec_template_packages = []
    if exec_platform_triples:
        exec_template_packages, exec_templates_by_fq_crate = _copy_resolutions(resolver_packages, exec_platform_triples)

    _resolve_possible_deps(
        resolver_packages,
        resolver_versions_by_name,
        feature_resolutions_by_fq_crate,
        platform_triples,
        platform_cfg_attrs,
        cfg_match_cache,
        dep_label_prefix,
    )

    if exec_platform_triples:
        _resolve_possible_deps(
            exec_template_packages,
            resolver_versions_by_name,
            exec_templates_by_fq_crate,
            exec_platform_triples,
            exec_platform_cfg_attrs_by_triple.values(),
            {None: struct(matches = exec_platform_triples, uses_feature_cfg = False)},
            dep_label_prefix,
        )

    workspace_dep_versions_by_name = {}
    workspace_dep_labels_by_triple = {platform_triple: set() for platform_triple in platform_triples}

    for package in cargo_metadata["packages"]:
        if watch_manifests:
            ctx.watch(package["manifest_path"])

        package_feature_resolutions = feature_resolutions_by_fq_crate[fq_crate(package["name"], package["version"])]
        package_feature_resolutions.active.update(platform_triples)
        if "default" in package.get("features", {}):
            for platform_triple in platform_triples:
                package_feature_resolutions.features_enabled[platform_triple].add("default")

        fq_deps = compute_package_fq_deps(
            workspace_members_by_key.get((package["name"], package["version"]), {}),
            resolver_versions_by_name,
        )

        for dep in package["dependencies"]:
            source = dep.get("source")
            dep_name = dep["name"]
            dep_package = _dep_package_name(dep)
            dep_fq = select_package_fq_dep(dep, fq_deps)
            if not dep_fq:
                continue
            dep_version = dep_fq[len(dep_package) + 1:]
            is_first_party_dep = not source and (dep_package, dep_version) in workspace_members_by_key

            if validate_lockfile and source and source.startswith("registry+"):
                req = dep["req"]
                if req and not select_matching_version(req, [dep_version]):
                    fail(("ERROR: Cargo.lock out of sync: %s requires %s %s but Cargo.lock has %s.\n\n" +
                          "If this is incorrect, please set `validate_lockfile = False` in `crate.from_cargo`\n" +
                          "and file a bug at https://github.com/hermeticbuild/rules_rs/issues/new") % (
                        package["name"],
                        dep_package,
                        req,
                        dep_version,
                    ))

            if dep_fq not in feature_resolutions_by_fq_crate:
                fail("Resolved %s dependency %s but no crate metadata was available" % (package["name"], dep_fq))

            if not is_first_party_dep or materialize_workspace_members:
                dep["bazel_target"] = "%s%s" % (dep_label_prefix, dep_fq)
                workspace_dep_versions_by_name.setdefault(dep_name, set()).add(dep_fq)

            if dep.get("kind", "normal") == "build":
                continue

            feature_resolutions = feature_resolutions_by_fq_crate[dep_fq]
            features = list(dep.get("features", []))
            if dep.get("uses_default_features"):
                features.append("default")

            target = dep.get("target")
            match_info = cfg_match_info_for_target(target, platform_cfg_attrs, cfg_match_cache)

            for platform_triple in match_info.matches:
                if not is_first_party_dep or materialize_workspace_members:
                    workspace_dep_labels_by_triple[platform_triple].add(":" + dep_name)
                feature_resolutions.active.add(platform_triple)
                feature_resolutions.features_enabled[platform_triple].update(features)

    binary_feature_resolutions = []
    for crate, annotation_versions in annotations.items():
        for version_key, annotation in annotation_versions.items():
            target_versions = resolver_versions_by_name.get(crate, [])
            if version_key != "*":
                if version_key not in target_versions:
                    continue
                target_versions = [version_key]
            gen_binaries = getattr(annotation, "gen_binaries", [])
            if not annotation.crate_features and not annotation.crate_features_select and not gen_binaries:
                continue
            for version in target_versions:
                fq = fq_crate(crate, version)
                _apply_annotation_features(feature_resolutions_by_fq_crate[fq], annotation)
                if gen_binaries:
                    binary_feature_resolutions.append(feature_resolutions_by_fq_crate[fq])

                if exec_platform_triples:
                    _apply_annotation_features(exec_templates_by_fq_crate[fq], annotation)

    resolve(ctx, resolver_packages, platform_cfg_attrs_by_triple, debug, include_build_dependencies = not exec_platform_triples)

    # Requested binaries are target roots even when their packages otherwise
    # occur only as build dependencies. Preserve features of packages already
    # reached through normal dependencies, including default-features = false.
    added_binary_roots = False
    for feature_resolutions in binary_feature_resolutions:
        if feature_resolutions.active:
            continue
        feature_resolutions.active.update(platform_triples)
        if "default" in feature_resolutions.possible_features:
            for features in feature_resolutions.features_enabled.values():
                features.add("default")
        added_binary_roots = True

    if added_binary_roots:
        resolve(ctx, resolver_packages, platform_cfg_attrs_by_triple, debug, include_build_dependencies = not exec_platform_triples)

    exec_resolutions_by_cargo_target_triple = _resolve_exec_targets(
        ctx,
        resolver_packages,
        exec_template_packages,
        platform_triples if exec_platform_triples else [],
        exec_platform_cfg_attrs_by_triple,
        debug,
    )

    for package in packages:
        feature_resolutions = package["feature_resolutions"]
        features_enabled = feature_resolutions.features_enabled

        for dep in feature_resolutions.possible_deps:
            if "bazel_target" in dep:
                continue

            prefixed_dep_alias = "dep:" + dep["name"]

            for platform_triple in platform_triples:
                if prefixed_dep_alias in features_enabled[platform_triple]:
                    fail("Crate %s has enabled %s but it was not in the lockfile..." % (package["name"], prefixed_dep_alias))

    return struct(
        cfg_match_cache = cfg_match_cache,
        exec_resolutions_by_cargo_target_triple = exec_resolutions_by_cargo_target_triple,
        feature_resolutions_by_fq_crate = feature_resolutions_by_fq_crate,
        platform_cfg_attrs = platform_cfg_attrs,
        workspace_dep_labels_by_triple = workspace_dep_labels_by_triple,
        workspace_dep_versions_by_name = workspace_dep_versions_by_name,
    )

def _workspace_deps(deps, local_deps):
    result = {}
    for label, alias in deps.items():
        local_dep = local_deps.get(label)
        if local_dep:
            label = local_dep.label
            if alias == None:
                alias = local_dep.alias
        result[label] = alias
    return result

def workspace_dep_data(
        *,
        cargo_metadata,
        dep_label_prefix,
        platform_triples,
        platform_cfg_attrs,
        cfg_match_cache,
        repo_root,
        workspace_package,
        use_legacy_rules_rust_platforms,
        configurations_by_crate,
        lint_configs = {}):
    workspace_crates_by_path = {
        normalize_path(package["manifest_path"]).removesuffix("/Cargo.toml"): fq_crate(package["name"], package["version"])
        for package in cargo_metadata["packages"]
    }
    dep_data = {}
    for package in cargo_metadata["packages"]:
        local_deps = {}
        dev_deps = {platform_triple: {} for platform_triple in platform_triples}
        package_dir = manifest_package_dir(package["manifest_path"], repo_root)
        package_manifest_dir = normalize_path(package["manifest_path"]).removesuffix("/Cargo.toml")
        package_key = fq_crate(package["name"], package["version"])

        for dep in package["dependencies"]:
            bazel_target = dep.get("bazel_target")
            dep_path = normalize_path(dep["path"]) if dep.get("path") else None
            if dep_path == package_manifest_dir:
                continue
            if not bazel_target:
                if not dep_path:
                    continue
                bazel_target = "//" + paths.join(workspace_package, dep_path.removeprefix(repo_root + "/"))
                workspace_crate = workspace_crates_by_path.get(dep_path)
                if workspace_crate:
                    local_deps[dep_label_prefix + workspace_crate] = struct(
                        label = bazel_target,
                        alias = dep["name"].replace("-", "_"),
                    )

            if dep["kind"] != "dev":
                continue

            alias = (dep.get("rename") or dep["name"]).replace("-", "_") if dep.get("rename") or dep_path else None

            match_info = cfg_match_info_for_target(dep.get("target"), platform_cfg_attrs, cfg_match_cache)
            for platform_triple in match_info.matches:
                dev_deps[platform_triple][bazel_target] = alias

        bazel_package = paths.join(workspace_package, package_dir) if package_dir else workspace_package

        dev_deps, dev_deps_by_platform = shared_and_per_platform(dev_deps, use_legacy_rules_rust_platforms)

        package_dep_data = {
            "crate_name": package["name"].replace("-", "_"),
            "dev_deps": dev_deps,
            "dev_deps_by_platform": dev_deps_by_platform,
            "edition": package.get("edition", "2015"),
        }
        lint_config = lint_configs.get(bazel_package)
        if lint_config:
            package_dep_data["lint_config"] = lint_config
        configurations = configurations_by_crate[package_key].configurations
        if local_deps:
            workspace_configurations = {}
            for cargo_target_triple, configuration in configurations.items():
                configuration = dict(configuration)
                configuration["deps_by_triple"] = {
                    platform_triple: _workspace_deps(deps, local_deps)
                    for platform_triple, deps in configuration["deps_by_triple"].items()
                }
                configuration["build_deps_by_triple"] = {
                    platform_triple: {
                        exec_platform_triple: _workspace_deps(deps, local_deps)
                        for exec_platform_triple, deps in deps_by_exec_triple.items()
                    }
                    for platform_triple, deps_by_exec_triple in configuration["build_deps_by_triple"].items()
                }
                workspace_configurations[cargo_target_triple] = configuration
            configurations = workspace_configurations
        package_dep_data["configurations"] = configurations
        dep_data[bazel_package] = package_dep_data

    return dep_data

def render_dep_data(dep_data):
    return "DEP_DATA = {\n%s\n}\n\n" % "\n".join([
        "    %s: %s," % (repr(package), repr(dep_data[package]))
        for package in sorted(dep_data)
    ])
