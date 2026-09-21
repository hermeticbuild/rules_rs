load("//rs/private:cfg_parser.bzl", "cfg_matches_expr_for_cfg_attrs")

def _count(packages):
    n = 0
    for package in packages:
        feature_resolutions = package["feature_resolutions"]
        for features in feature_resolutions.features_enabled.values():
            n += len(features)

        for build_deps in feature_resolutions.build_deps.values():
            n += len(build_deps)

        for deps in feature_resolutions.deps.values():
            n += len(deps)

        # No need to count aliases, they only get set when deps are set.
    return n

def _dep_target_matches_triple(dep, triple, package_feature_set, cfg_attrs_by_triple):
    if triple not in dep["target"]:
        return False

    if "target_expr" not in dep:
        return True

    cfg_attr = cfg_attrs_by_triple[triple]
    return bool(cfg_matches_expr_for_cfg_attrs(
        dep["target_expr"],
        [cfg_attr],
        features = package_feature_set,
    ).matches)

def _resolve_one_round(packages, dirty_package_indices, cfg_attrs_by_triple, debug, include_build_dependencies, restrict_to_active_platforms):
    new_dirty_package_indices = set()

    for index in dirty_package_indices:
        package = packages[index]
        feature_resolutions = package["feature_resolutions"]
        if not feature_resolutions.active:
            continue
        features_enabled = feature_resolutions.features_enabled

        # A normal dependency can be a proc macro compiled for an execution
        # platform. Preserve its dependencies on every configured platform;
        # proc-macro metadata is only available after fetching its archive.
        if not restrict_to_active_platforms:
            feature_resolutions.active.update(features_enabled)

        _propagate_feature_enablement(
            new_dirty_package_indices,
            package,
            cfg_attrs_by_triple,
            debug,
            include_build_dependencies,
        )

        # Propagate features across currently enabled dependencies.
        for dep in feature_resolutions.possible_deps:
            bazel_target = dep.get("bazel_target")
            if not bazel_target:
                continue

            kind = dep.get("kind", "normal")
            if kind == "build" and not include_build_dependencies:
                continue
            deps = feature_resolutions.deps if kind == "normal" else feature_resolutions.build_deps

            dep_feature_resolutions = dep["feature_resolutions"]
            dep_features = dep.get("features")

            has_alias = "package" in dep
            dep_name = dep["name"]
            prefixed_dep_alias = "dep:" + dep_name
            optional = dep.get("optional", False)

            feature_sensitive = "target_expr" in dep
            for triple in dep["target"]:
                if triple not in feature_resolutions.active:
                    continue
                if feature_sensitive and not _dep_target_matches_triple(dep, triple, features_enabled[triple], cfg_attrs_by_triple):
                    continue

                if optional:
                    features_for_triple = features_enabled[triple]
                    if dep_name not in features_for_triple and prefixed_dep_alias not in features_for_triple:
                        continue

                deps[triple].add(bazel_target)

                if has_alias:
                    feature_resolutions.aliases[bazel_target] = dep_name.replace("-", "_")

                if triple not in dep_feature_resolutions.active:
                    dep_feature_resolutions.active.add(triple)
                    new_dirty_package_indices.add(dep_feature_resolutions.package_index)

                if dep_features:
                    triple_features = dep_feature_resolutions.features_enabled[triple]
                    prev_length = len(triple_features)
                    triple_features.update(dep_features)
                    if prev_length != len(triple_features):
                        new_dirty_package_indices.add(dep_feature_resolutions.package_index)

    return new_dirty_package_indices

def _propagate_feature_enablement(
        dirty_package_indices,
        package,
        cfg_attrs_by_triple,
        debug,
        include_build_dependencies):
    feature_resolutions = package["feature_resolutions"]
    possible_features = feature_resolutions.possible_features

    for triple in feature_resolutions.active:
        feature_set = feature_resolutions.features_enabled[triple]
        if not feature_set:
            continue

        # Enable any features that are implied by previously-enabled features.
        for enabled_feature in list(feature_set):
            enables = possible_features.get(enabled_feature)
            if not enables:
                continue

            for feature in enables:
                idx = feature.find("/")
                if idx == -1:
                    if feature not in feature_set:
                        feature_set.add(feature)
                        dirty_package_indices.add(feature_resolutions.package_index)
                    continue

                dep_name = feature[:idx]
                dep_feature = feature[idx + 1:]

                has_optional_dependency = False
                optional_marker = False
                if dep_name[-1] == "?":
                    optional_marker = True
                    dep_name = dep_name[:-1]

                found = False
                for dep in feature_resolutions.possible_deps:
                    if "feature_resolutions" not in dep:
                        continue
                    if dep_name != dep["name"]:
                        continue

                    defer_build_dependency = dep.get("kind", "normal") == "build" and not include_build_dependencies
                    if not defer_build_dependency and not _dep_target_matches_triple(dep, triple, feature_set, cfg_attrs_by_triple):
                        continue

                    found = True
                    dep_optional = dep.get("optional", False)
                    has_optional_dependency = has_optional_dependency or dep_optional
                    if optional_marker and dep_optional and dep_name not in feature_set and ("dep:" + dep_name) not in feature_set:
                        continue

                    if defer_build_dependency:
                        dep.setdefault("deferred_features", {}).setdefault(triple, set()).add(dep_feature)
                    else:
                        dep_feature_resolutions = dep["feature_resolutions"]
                        triple_features = dep_feature_resolutions.features_enabled[triple]
                        if dep_feature not in triple_features:
                            triple_features.add(dep_feature)
                            dirty_package_indices.add(dep_feature_resolutions.package_index)

                # Only optional deps need to be explicitly enabled when a subfeature is toggled.
                if has_optional_dependency and (not optional_marker) and dep_name not in feature_set:
                    feature_set.add(dep_name)
                    dirty_package_indices.add(feature_resolutions.package_index)

                if not found and debug:
                    print("Skipping enabling subfeature", feature, "for", package["name"], "@", package["version"], "it's not a dep...")

_MAX_ROUNDS = 200

def resolve(mctx, packages, cfg_attrs_by_triple, debug, include_build_dependencies = True, restrict_to_active_platforms = False):
    # Do some rounds of mutual resolution; bail when no more changes
    dirty_package_indices = range(len(packages))

    for i in range(_MAX_ROUNDS):
        if mctx:
            mctx.report_progress("Running round %s of dependency/feature resolution" % i)

        dirty_package_indices = _resolve_one_round(packages, dirty_package_indices, cfg_attrs_by_triple, debug, include_build_dependencies, restrict_to_active_platforms)
        if not dirty_package_indices:
            if debug:
                count = _count(packages)
                print("Got count", count, "in", i + 1, "rounds")
            return
        dirty_package_indices = sorted(dirty_package_indices)

    fail("Resolution did not converge after %s rounds! This is likely a bug in rules_rs, please report it to github.com/hermeticbuild/rules_rs" % _MAX_ROUNDS)

def collect_exec_build_dependencies(packages, exec_template_packages, exec_cfg_attrs_by_triple, target_triple):
    """Collect execution seeds and owner dependencies for one target triple."""
    features = {}
    build_deps = {}
    aliases = {}
    for package, exec_package in zip(packages, exec_template_packages):
        target_resolution = package["feature_resolutions"]
        exec_resolution = exec_package["feature_resolutions"]

        if target_triple not in target_resolution.active:
            continue

        target_features = target_resolution.features_enabled[target_triple]
        owner = package["name"] + "-" + package["version"]

        for target_dep, dep in zip(target_resolution.possible_deps, exec_resolution.possible_deps):
            bazel_target = dep.get("bazel_target")
            if dep.get("kind", "normal") != "build" or not bazel_target:
                continue

            dep_name = dep["name"]
            if dep.get("optional", False) and dep_name not in target_features and ("dep:" + dep_name) not in target_features:
                continue

            dep_resolution = dep["feature_resolutions"]
            feature_sensitive = "target_expr" in dep
            for exec_triple in dep["target"]:
                if feature_sensitive and not _dep_target_matches_triple(dep, exec_triple, target_features, exec_cfg_attrs_by_triple):
                    continue

                if owner not in build_deps:
                    build_deps[owner] = {triple: set() for triple in exec_cfg_attrs_by_triple}
                build_deps[owner][exec_triple].add(bazel_target)
                if "package" in dep:
                    aliases.setdefault(owner, {})[bazel_target] = dep_name.replace("-", "_")

                requested_features = features.setdefault((dep_resolution.package_index, exec_triple), set())
                requested_features.update(dep_resolution.features_enabled[exec_triple])
                requested_features.update(dep.get("features", []))
                requested_features.update(target_dep.get("deferred_features", {}).get(target_triple, []))

    return struct(features = features, build_deps = build_deps, aliases = aliases)
