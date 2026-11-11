load("@bazel_skylib//lib:paths.bzl", "paths")
load("//rs/private:cfg_parser.bzl", "cfg_matches_expr_for_cfg_attrs", "triple_to_cfg_attrs")
load("//rs/private:resolver.bzl", "resolve")
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

def exclude_deps_from_features(features):
    return [f for f in features if not f.startswith("dep:")]

def shared_and_per_platform(platform_items, use_legacy_rules_rust_platforms):
    by_platform = {}
    for triple, items in platform_items.items():
        platform = platform_label(triple, use_legacy_rules_rust_platforms)
        by_platform.setdefault(platform, set()).update(items)

    items, per_platform = compute_select([], by_platform)
    return sorted(items), per_platform

def render_string_list(items):
    return ",\n            ".join(['"%s"' % item for item in sorted(items)])

def cargo_platforms(triples):
    attrs = {triple: triple_to_cfg_attrs(triple) for triple in triples}
    bits = {}
    bit = 1
    for triple in attrs:
        bits[triple] = bit
        bit <<= 1
    all_platforms = bit - 1
    return struct(
        attrs = attrs,
        all_mask = all_platforms,
        bits = bits,
        targets = {None: struct(matches = attrs.keys(), mask = all_platforms, feature_cfg = None)},
    )

def _match_target(target, platforms):
    info = platforms.targets.get(target)
    if info == None:
        match = cfg_matches_expr_for_cfg_attrs(target, platforms.attrs.values())
        mask = 0
        for triple in match.matches:
            mask |= platforms.bits[triple]
        info = struct(matches = match.matches, mask = mask, feature_cfg = match.feature_cfg)
        platforms.targets[target] = info
    return info

def new_feature_resolutions(package_index, possible_deps, possible_features):
    return struct(
        feature_seeds = [],
        features_enabled = {},
        build_deps = {},
        deps = {},
        aliases = {},
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
        "features": dep.get("features", []),
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

        for dep, spec in value.get("build-dependencies", {}).items():
            dependencies.append(cargo_toml_dep_to_dep_dict(
                dep,
                spec,
                package_name,
                workspace_cargo_toml_json,
                is_build = True,
                target = target,
            ))

    return dependencies

def cargo_toml_fact(cargo_toml_json, workspace_cargo_toml_json = None, strip_prefix = ""):
    return dict(
        features = cargo_toml_json.get("features", {}),
        dependencies = cargo_toml_dependencies(cargo_toml_json, workspace_cargo_toml_json),
        strip_prefix = strip_prefix,
    )

def prepare_possible_deps(dependencies, converter = None, skip_internal_rustc_placeholder_crates = True):
    possible_deps = []

    for dep in dependencies:
        dep = converter(dep) if converter else dict(dep)

        if dep.get("kind") == "dev":
            continue

        dep_package = dep.get("package") or dep["name"]
        if skip_internal_rustc_placeholder_crates and dep_package in _INTERNAL_RUSTC_PLACEHOLDER_CRATES:
            continue

        if dep.get("default_features", True):
            dep["features"] = dep.get("features", []) + ["default"]

        possible_deps.append(dep)

    return possible_deps

def _dep_package_name(dep):
    return dep.get("package") or dep["name"]

def locked_dependency_versions(package, versions_by_name = {}):
    locked = {}
    for entry in package.get("dependencies", []):
        name, separator, version = entry.partition(" ")
        if not separator:
            versions = versions_by_name.get(name)
            if not versions:
                continue
            version = versions[0]
        locked.setdefault(name, []).append(version)
    return locked

def select_dependency_version(dep, versions_by_name):
    versions = versions_by_name.get(_dep_package_name(dep), [])
    if len(versions) == 1:
        return versions[0]
    req = dep.get("req")
    return select_matching_version(req, versions) if versions and req else None

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

def _workspace_member_keys(cargo_metadata):
    return set([(package["name"], package["version"]) for package in cargo_metadata["packages"]])

def split_lockfile_packages(hub_name, cargo_metadata, workspace_cargo_toml, all_packages, repo_root = None, workspace_package_dir = ""):
    if repo_root == None:
        repo_root = cargo_metadata["workspace_root"]
    repo_root = normalize_path(repo_root)

    workspace_member_keys = _workspace_member_keys(cargo_metadata)
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

def resolve_package_facts(packages, facts_by_fq_crate, *, dep_converter = None, skip_internal_rustc_placeholder_crates = True):
    feature_resolutions_by_fq_crate = {}
    versions_by_name = {}

    for package_index, package in enumerate(packages):
        name = package["name"]
        version = package["version"]
        fq = fq_crate(name, version)

        versions_by_name.setdefault(name, []).append(version)

        package_info = facts_by_fq_crate[fq]
        possible_deps = prepare_possible_deps(
            package_info.get("dependencies", []),
            converter = dep_converter,
            skip_internal_rustc_placeholder_crates = skip_internal_rustc_placeholder_crates,
        )
        feature_resolutions = new_feature_resolutions(package_index, possible_deps, package_info.get("features", {}))
        package["feature_resolutions"] = feature_resolutions
        feature_resolutions_by_fq_crate[fq] = feature_resolutions

    return struct(
        feature_resolutions_by_fq_crate = feature_resolutions_by_fq_crate,
        versions_by_name = versions_by_name,
    )

def resolve_cargo_metadata_packages(packages, cargo_metadata, skip_internal_rustc_placeholder_crates = True):
    metadata_by_fq_crate = {
        fq_crate(package["name"], package["version"]): package
        for package in cargo_metadata["packages"]
    }

    return resolve_package_facts(
        packages,
        metadata_by_fq_crate,
        dep_converter = cargo_metadata_dep_to_dep_dict,
        skip_internal_rustc_placeholder_crates = skip_internal_rustc_placeholder_crates,
    )

def _resolve_possible_deps(
        packages,
        resolver_versions_by_name,
        feature_resolutions_by_fq_crate,
        platforms,
        dep_label_prefix):
    for package in packages:
        name = package["name"]
        locked = locked_dependency_versions(package)
        for dep in package["feature_resolutions"].possible_deps:
            dep_package = _dep_package_name(dep)
            if dep_package not in resolver_versions_by_name:
                continue
            versions = locked if dep_package in locked else resolver_versions_by_name
            resolved_version = select_dependency_version(dep, versions)
            if not resolved_version:
                if dep.get("req") and not dep.get("optional"):
                    print("WARNING: %s: could not resolve %s %s among %s" % (name, dep_package, dep["req"], versions[dep_package]))
                continue

            dep_fq = fq_crate(dep_package, resolved_version)
            if dep_fq not in feature_resolutions_by_fq_crate:
                fail("Resolved %s dependency %s but no crate metadata was available" % (name, dep_fq))
            dep["bazel_target"] = "%s%s" % (dep_label_prefix, dep_fq)
            dep["package_index"] = feature_resolutions_by_fq_crate[dep_fq].package_index

            info = _match_target(dep.get("target"), platforms)

            # A feature predicate can become true after other features are enabled.
            dep["platforms"] = platforms.all_mask if info.feature_cfg else info.mask
            if info.feature_cfg:
                dep["feature_cfg"] = info.feature_cfg

def resolve_cargo_workspace_members(
        ctx,
        *,
        cargo_metadata,
        packages,
        workspace_members,
        package_resolution,
        annotations,
        platforms,
        materialize_workspace_members,
        validate_lockfile = True,
        debug = False,
        dep_label_prefix = "//:",
        skip_internal_rustc_placeholder_crates = True):
    platform_triples = platforms.bits.keys()

    feature_resolutions_by_fq_crate = package_resolution.feature_resolutions_by_fq_crate
    resolver_versions_by_name = dict(package_resolution.versions_by_name)
    workspace_member_keys = _workspace_member_keys(cargo_metadata)
    workspace_members_by_key = {(package["name"], package["version"]): package for package in workspace_members}
    resolver_packages = packages[:]
    for package in cargo_metadata["packages"]:
        name = package["name"]
        version = package["version"]

        versions = resolver_versions_by_name.get(name, [])
        if version not in versions:
            resolver_versions_by_name[name] = versions + [version]

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

        feature_resolutions = new_feature_resolutions(package_index, possible_deps, possible_features)
        resolver_package["feature_resolutions"] = feature_resolutions
        feature_resolutions_by_fq_crate[fq_crate(name, version)] = feature_resolutions

        resolver_packages.append(resolver_package)

    _resolve_possible_deps(
        resolver_packages,
        resolver_versions_by_name,
        feature_resolutions_by_fq_crate,
        platforms,
        dep_label_prefix,
    )

    workspace_versions = {p["name"]: locked_dependency_versions(p, resolver_versions_by_name) for p in workspace_members}
    workspace_dep_versions_by_name = {}
    workspace_dep_labels_by_triple = {triple: set() for triple in platform_triples}

    for package in cargo_metadata["packages"]:
        package_feature_resolutions = feature_resolutions_by_fq_crate[fq_crate(package["name"], package["version"])]
        if "default" in package.get("features", {}):
            package_feature_resolutions.feature_seeds.append((["default"], platforms.all_mask))

        locked = workspace_versions.get(package["name"], {})

        for dep in package["dependencies"]:
            source = dep.get("source")
            dep_name = dep["name"]
            dep_package = _dep_package_name(dep)
            locked_version = select_dependency_version(dep, locked)
            if not locked_version:
                continue
            dep_fq = fq_crate(dep_package, locked_version)
            is_first_party_dep = not source and (dep_package, locked_version) in workspace_member_keys

            if validate_lockfile and source and source.startswith("registry+"):
                req = dep["req"]
                if req and not select_matching_version(req, [locked_version]):
                    fail(("ERROR: Cargo.lock out of sync: %s requires %s %s but Cargo.lock has %s.\n\n" +
                          "If this is incorrect, please set `validate_lockfile = False` in `crate.from_cargo`\n" +
                          "and file a bug at https://github.com/hermeticbuild/rules_rs/issues/new") % (
                        package["name"],
                        dep_package,
                        req,
                        locked_version,
                    ))

            features = dep.get("features", [])
            if dep.get("uses_default_features"):
                features = features + ["default"]

            if dep_fq not in feature_resolutions_by_fq_crate:
                fail("Resolved %s dependency %s but no crate metadata was available" % (package["name"], dep_fq))

            match = _match_target(dep.get("target"), platforms)
            feature_resolutions_by_fq_crate[dep_fq].feature_seeds.append((features, match.mask))
            if materialize_workspace_members or not is_first_party_dep:
                dep["bazel_target"] = "%s%s" % (dep_label_prefix, dep_fq)
                workspace_dep_versions_by_name.setdefault(dep_name, set()).add(dep_fq)
                for triple in match.matches:
                    workspace_dep_labels_by_triple[triple].add(":" + dep_name)

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
                seeds = feature_resolutions_by_fq_crate[fq_crate(crate, version)].feature_seeds
                if annotation.crate_features:
                    seeds.append((annotation.crate_features, platforms.all_mask))
                for triple, features in annotation.crate_features_select.items():
                    if triple in platforms.bits:
                        seeds.append((features, platforms.bits[triple]))

    resolve(ctx, resolver_packages, platforms, debug)

    for package in packages:
        feature_resolutions = package["feature_resolutions"]
        features_enabled = feature_resolutions.features_enabled

        for dep in feature_resolutions.possible_deps:
            if "bazel_target" in dep:
                continue

            prefixed_dep_alias = "dep:" + dep["name"]

            for triple in platform_triples:
                if prefixed_dep_alias in features_enabled[triple]:
                    fail("Crate %s has enabled %s but it was not in the lockfile..." % (package["name"], prefixed_dep_alias))

    return struct(
        workspace_dep_labels_by_triple = workspace_dep_labels_by_triple,
        workspace_dep_versions_by_name = workspace_dep_versions_by_name,
    )

def workspace_dep_data(
        *,
        cargo_metadata,
        feature_resolutions_by_fq_crate,
        platforms,
        repo_root,
        workspace_package,
        use_legacy_rules_rust_platforms,
        lint_configs = {}):
    platform_triples = platforms.bits.keys()
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

            if dep_path and normalize_path(dep_path) == package_manifest_dir:
                continue
            if dep.get("rename") or dep_path:
                aliases[bazel_target] = (dep.get("rename") or dep["name"]).replace("-", "_")

            match = _match_target(dep.get("target"), platforms).matches

            kind = dep["kind"]
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

                target_deps[triple].add(bazel_target)

        if feature_resolutions:
            for triple in platform_triples:
                crate_features[triple].update(exclude_deps_from_features(feature_resolutions.features_enabled[triple]))

        bazel_package = paths.join(workspace_package, package_dir) if package_dir else workspace_package

        crate_features, crate_features_by_platform = shared_and_per_platform(crate_features, use_legacy_rules_rust_platforms)
        deps, deps_by_platform = shared_and_per_platform(deps, use_legacy_rules_rust_platforms)
        build_deps, build_deps_by_platform = shared_and_per_platform(build_deps, use_legacy_rules_rust_platforms)
        dev_deps, dev_deps_by_platform = shared_and_per_platform(dev_deps, use_legacy_rules_rust_platforms)

        package_dep_data = {
            "aliases": aliases,
            "binaries": binaries,
            "build_deps": build_deps,
            "build_deps_by_platform": build_deps_by_platform,
            "crate_features": crate_features,
            "crate_features_by_platform": crate_features_by_platform,
            "crate_name": package["name"].replace("-", "_"),
            "deps": deps,
            "deps_by_platform": deps_by_platform,
            "dev_deps": dev_deps,
            "dev_deps_by_platform": dev_deps_by_platform,
            "edition": package.get("edition", "2015"),
            "shared_libraries": shared_libraries,
        }
        lint_config = lint_configs.get(bazel_package)
        if lint_config:
            package_dep_data["lint_config"] = lint_config
        dep_data[bazel_package] = package_dep_data

    return dep_data

def render_dep_data(dep_data):
    return "DEP_DATA = {\n%s\n}\n\n" % "\n".join([
        "    %s: %s," % (repr(package), repr(dep_data[package]))
        for package in sorted(dep_data.keys())
    ])
