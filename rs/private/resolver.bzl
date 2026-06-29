load("//rs/private:cfg_parser.bzl", "cfg_matches_expr_for_cfg_attrs")

def _count(feature_resolutions_by_fq_crate):
    n = 0
    for feature_resolutions in feature_resolutions_by_fq_crate.values():
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

    if not dep.get("feature_sensitive", False):
        return True

    cfg_attr = cfg_attrs_by_triple[triple]
    return bool(cfg_matches_expr_for_cfg_attrs(
        dep["target_expr"],
        [cfg_attr],
        features = package_feature_set,
    ).matches)

def _resolve_one_round(packages, dirty_package_indices, cfg_attrs_by_triple, debug, include_build_dependencies):
    new_dirty_package_indices = set()

    for index in dirty_package_indices:
        package = packages[index]
        package_changed = False

        feature_resolutions = package["feature_resolutions"]
        features_enabled = feature_resolutions.features_enabled

        deps = feature_resolutions.deps

        if _propagate_feature_enablement(
            new_dirty_package_indices,
            package,
            features_enabled,
            feature_resolutions,
            cfg_attrs_by_triple,
            debug,
            include_build_dependencies,
        ):
            package_changed = True

        # Propagate features across currently enabled dependencies.
        for dep in feature_resolutions.possible_deps:
            bazel_target = dep.get("bazel_target")
            if not bazel_target:
                continue

            kind = dep.get("kind", "normal")
            if kind == "build" and not include_build_dependencies:
                continue

            defer_proc_macro = dep.get("is_proc_macro", False) and not include_build_dependencies

            dep_feature_resolutions = dep["feature_resolutions"]

            has_alias = "package" in dep
            dep_name = dep["name"]
            prefixed_dep_alias = "dep:" + dep_name
            optional = dep.get("optional", False)

            if dep.get("feature_sensitive"):
                match = set([
                    triple
                    for triple in dep["target"]
                    if _dep_target_matches_triple(dep, triple, features_enabled[triple], cfg_attrs_by_triple)
                ])
            else:
                match = dep["target"]

            for triple in match:
                if triple not in feature_resolutions.active:
                    continue

                if optional:
                    features_for_triple = features_enabled[triple]
                    if dep_name not in features_for_triple and prefixed_dep_alias not in features_for_triple:
                        continue

                triple_deps = deps[triple] if kind == "normal" else feature_resolutions.build_deps[triple]
                if bazel_target not in triple_deps:
                    package_changed = True
                    triple_deps.add(bazel_target)

                if has_alias:
                    feature_resolutions.aliases[bazel_target] = dep_name.replace("-", "_")

                if defer_proc_macro:
                    continue

                triple_features = dep_feature_resolutions.features_enabled[triple]

                if triple not in dep_feature_resolutions.active:
                    dep_feature_resolutions.active.add(triple)
                    new_dirty_package_indices.add(dep_feature_resolutions.package_index)

                dep_features = dep.get("features")
                if dep_features:
                    prev_length = len(triple_features)
                    triple_features.update(dep_features)
                    if prev_length != len(triple_features):
                        new_dirty_package_indices.add(dep_feature_resolutions.package_index)

        if package_changed:
            new_dirty_package_indices.add(index)

    return new_dirty_package_indices

def _propagate_feature_enablement(
        dirty_package_indices,
        package,
        features_enabled,
        feature_resolutions,
        cfg_attrs_by_triple,
        debug,
        include_build_dependencies):
    package_changed = False
    possible_features = feature_resolutions.possible_features

    for triple, feature_set in features_enabled.items():
        if triple not in feature_resolutions.active or not feature_set:
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
                        package_changed = True
                        feature_set.add(feature)
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
                    if dep_name != dep["name"]:
                        continue

                    defer_dependency = not include_build_dependencies and (dep.get("kind", "normal") == "build" or dep.get("is_proc_macro", False))
                    if not defer_dependency and not _dep_target_matches_triple(dep, triple, feature_set, cfg_attrs_by_triple):
                        continue

                    found = True
                    dep_optional = dep.get("optional", False)
                    has_optional_dependency = has_optional_dependency or dep_optional
                    if optional_marker and dep_optional and dep_name not in feature_set and ("dep:" + dep_name) not in feature_set:
                        continue

                    if defer_dependency:
                        dep.setdefault("deferred_features", set()).add(dep_feature)
                    else:
                        dep_feature_resolutions = dep["feature_resolutions"]
                        triple_features = dep_feature_resolutions.features_enabled[triple]
                        if dep_feature not in triple_features:
                            triple_features.add(dep_feature)
                            dirty_package_indices.add(dep_feature_resolutions.package_index)

                # Only optional deps need to be explicitly enabled when a subfeature is toggled.
                if has_optional_dependency and (not optional_marker) and dep_name not in feature_set:
                    package_changed = True
                    feature_set.add(dep_name)

                if not found and debug:
                    print("Skipping enabling subfeature", feature, "for", package["name"], "@", package["version"], "it's not a dep...")

    return package_changed

_MAX_ROUNDS = 50

def resolve(mctx, packages, feature_resolutions_by_fq_crate, cfg_attrs_by_triple, debug, include_build_dependencies = True):
    # Do some rounds of mutual resolution; bail when no more changes
    dirty_package_indices = range(len(packages))
    for i in range(_MAX_ROUNDS):
        mctx.report_progress("Running round %s of dependency/feature resolution" % i)

        dirty_package_indices = _resolve_one_round(packages, dirty_package_indices, cfg_attrs_by_triple, debug, include_build_dependencies)
        if not dirty_package_indices:
            if debug:
                count = _count(feature_resolutions_by_fq_crate)
                print("Got count", count, "in", i + 1, "rounds")
            return
        dirty_package_indices = sorted(dirty_package_indices)

    fail("Resolution did not converge! This is likely a bug in rules_rs, please report it to github.com/hermeticbuild/rules_rs")

def seed_exec_build_dependencies(packages, exec_packages, exec_cfg_attrs_by_triple):
    """Seeds exec resolution from build dependencies and annotated proc macros."""
    for package, exec_package in zip(packages, exec_packages):
        target_resolution = package["feature_resolutions"]
        exec_resolution = exec_package["feature_resolutions"]

        if not target_resolution.active:
            continue

        target_features = set()
        for triple in target_resolution.active:
            target_features.update(target_resolution.features_enabled[triple])

        for target_dep, dep in zip(target_resolution.possible_deps, exec_resolution.possible_deps):
            bazel_target = dep.get("bazel_target")
            is_build_dependency = dep.get("kind", "normal") == "build"
            is_proc_macro = dep.get("is_proc_macro", False)
            if not bazel_target or not (is_build_dependency or is_proc_macro):
                continue

            dep_name = dep["name"]
            if dep.get("optional", False) and dep_name not in target_features and ("dep:" + dep_name) not in target_features:
                continue

            target_bazel_target = target_dep.get("bazel_target")
            if is_proc_macro and not any([target_bazel_target in deps for deps in target_resolution.deps.values()]):
                continue

            dep_resolution = dep["feature_resolutions"]
            exec_triples = dep_resolution.features_enabled.keys() if is_proc_macro else dep["target"]
            for exec_triple in exec_triples:
                if is_build_dependency:
                    if not _dep_target_matches_triple(dep, exec_triple, target_features, exec_cfg_attrs_by_triple):
                        continue
                    target_resolution.build_deps[exec_triple].add(bazel_target)
                    if "package" in dep:
                        target_resolution.aliases[bazel_target] = dep_name.replace("-", "_")
                dep_resolution.active.add(exec_triple)
                dep_resolution.features_enabled[exec_triple].update(dep.get("features", []))
                dep_resolution.features_enabled[exec_triple].update(target_dep.get("deferred_features", []))
