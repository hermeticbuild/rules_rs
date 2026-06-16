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

        for host_deps in feature_resolutions.host_deps.values():
            n += len(host_deps)

        for host_features in feature_resolutions.host_features_enabled.values():
            n += len(host_features)

        for host_activated in feature_resolutions.host_activated.values():
            if host_activated:
                n += 1

        # No need to count aliases, they only get set when deps are set.
    return n

def _dep_target_matches_triple(dep, triple, package_feature_set, cfg_attrs_by_triple):
    remaining = dep["target"]
    if triple not in remaining:
        return False

    if not dep.get("feature_sensitive", False):
        return True

    cfg_attr = cfg_attrs_by_triple[triple]
    return bool(cfg_matches_expr_for_cfg_attrs(
        dep["target_expr"],
        [cfg_attr],
        features = package_feature_set,
    ).matches)

def _resolve_one_round(packages, dirty_package_indices, cfg_attrs_by_triple, debug):
    new_dirty_package_indices = set()

    for index in dirty_package_indices:
        package = packages[index]
        package_changed = False

        feature_resolutions = package["feature_resolutions"]
        features_enabled = feature_resolutions.features_enabled
        host_features_enabled = feature_resolutions.host_features_enabled

        deps = feature_resolutions.deps
        host_deps = feature_resolutions.host_deps

        if _propagate_feature_enablement(
            package_changed,
            new_dirty_package_indices,
            package,
            features_enabled,
            feature_resolutions,
            cfg_attrs_by_triple,
            debug,
        ):
            package_changed = True

        if _propagate_feature_enablement(
            package_changed,
            new_dirty_package_indices,
            package,
            host_features_enabled,
            feature_resolutions,
            cfg_attrs_by_triple,
            debug,
            host = True,
        ):
            package_changed = True

        # Propagate features across currently enabled dependencies.
        for dep in feature_resolutions.possible_deps:
            bazel_target = dep.get("bazel_target")
            if not bazel_target:
                continue
            host_bazel_target = dep.get("host_bazel_target", bazel_target)

            kind = dep.get("kind", "normal")

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

            to_remove = None
            for triple in match:
                if optional:
                    features_for_triple = features_enabled[triple]
                    if dep_name not in features_for_triple and prefixed_dep_alias not in features_for_triple:
                        continue

                if kind == "normal":
                    triple_deps = deps[triple]
                    dep_target = bazel_target
                    dep_features_by_triple = dep_feature_resolutions.features_enabled
                else:
                    triple_deps = feature_resolutions.build_deps[triple]
                    dep_target = host_bazel_target
                    dep_features_by_triple = dep_feature_resolutions.host_features_enabled
                    if not dep_feature_resolutions.host_activated[triple]:
                        dep_feature_resolutions.host_activated[triple] = True
                        new_dirty_package_indices.add(dep_feature_resolutions.package_index)

                if package_changed or dep_target not in triple_deps:
                    package_changed = True
                    triple_deps.add(dep_target)

                if has_alias:
                    feature_resolutions.aliases[dep_target] = dep_name.replace("-", "_")

                triple_features = dep_features_by_triple[triple]

                dep_features = dep.get("features")
                if dep_features:
                    prev_length = len(triple_features)
                    triple_features.update(dep_features)
                    if prev_length != len(triple_features):
                        new_dirty_package_indices.add(dep_feature_resolutions.package_index)
                if not to_remove:
                    to_remove = set()
                to_remove.add(triple)

            if to_remove:
                if len(to_remove) == len(match):
                    dep["bazel_target"] = None
                else:
                    match.difference_update(to_remove)

        if _propagate_host_deps(
            package_changed,
            new_dirty_package_indices,
            feature_resolutions,
            host_features_enabled,
            host_deps,
            cfg_attrs_by_triple,
        ):
            package_changed = True

        if package_changed:
            new_dirty_package_indices.add(index)

    return new_dirty_package_indices

def _propagate_host_deps(
        package_changed,
        dirty_package_indices,
        feature_resolutions,
        host_features_enabled,
        host_deps,
        cfg_attrs_by_triple):
    for dep in feature_resolutions.possible_deps:
        host_bazel_target = dep.get("host_bazel_target")
        if not host_bazel_target:
            continue
        if dep.get("kind", "normal") != "normal":
            continue

        dep_feature_resolutions = dep["feature_resolutions"]
        dep_name = dep["name"]
        prefixed_dep_alias = "dep:" + dep_name
        optional = dep.get("optional", False)

        for triple in dep["target"]:
            if not feature_resolutions.host_activated[triple]:
                continue

            if not _dep_target_matches_triple(dep, triple, host_features_enabled[triple], cfg_attrs_by_triple):
                continue

            if optional:
                features_for_triple = host_features_enabled[triple]
                if dep_name not in features_for_triple and prefixed_dep_alias not in features_for_triple:
                    continue

            triple_deps = host_deps[triple]
            if host_bazel_target not in triple_deps:
                package_changed = True
                triple_deps.add(host_bazel_target)

            dep_features = dep.get("features")
            if not dep_feature_resolutions.host_activated[triple]:
                dep_feature_resolutions.host_activated[triple] = True
                dirty_package_indices.add(dep_feature_resolutions.package_index)
            if dep_features:
                triple_features = dep_feature_resolutions.host_features_enabled[triple]
                prev_length = len(triple_features)
                triple_features.update(dep_features)
                if prev_length != len(triple_features):
                    dirty_package_indices.add(dep_feature_resolutions.package_index)

    return package_changed

def _propagate_feature_enablement(
        package_changed,
        dirty_package_indices,
        package,
        features_enabled,
        feature_resolutions,
        cfg_attrs_by_triple,
        debug,
        host = False):
    possible_features = feature_resolutions.possible_features

    for triple, feature_set in features_enabled.items():
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
                        package_changed = True
                        feature_set.add(feature)
                    continue

                dep_name = feature[:idx]
                dep_feature = feature[idx + 1:]

                dep_optional = False
                optional_marker = False
                if dep_name[-1] == "?":
                    optional_marker = True
                    dep_name = dep_name[:-1]

                found = False
                for dep in feature_resolutions.possible_deps:
                    if dep_name == dep["name"] and _dep_target_matches_triple(dep, triple, feature_set, cfg_attrs_by_triple):
                        found = True
                        dep_optional = dep.get("optional", False)
                        if not optional_marker or not dep_optional or dep_name in feature_set or ("dep:" + dep_name) in feature_set:
                            dep_feature_resolutions = dep["feature_resolutions"]
                            if host or dep.get("kind", "normal") != "normal":
                                triple_features = dep_feature_resolutions.host_features_enabled[triple]
                                if not dep_feature_resolutions.host_activated[triple]:
                                    dep_feature_resolutions.host_activated[triple] = True
                                    dirty_package_indices.add(dep_feature_resolutions.package_index)
                            else:
                                triple_features = dep_feature_resolutions.features_enabled[triple]
                            if dep_feature not in triple_features:
                                triple_features.add(dep_feature)
                                dirty_package_indices.add(dep_feature_resolutions.package_index)
                        break

                # Only optional deps need to be explicitly enabled when a subfeature is toggled.
                if dep_optional and (not optional_marker) and dep_name not in feature_set:
                    package_changed = True
                    feature_set.add(dep_name)

                if not found and debug:
                    print("Skipping enabling subfeature", feature, "for", package["name"], "@", package["version"], "it's not a dep...")

    return package_changed

_MAX_ROUNDS = 50

def resolve(mctx, packages, feature_resolutions_by_fq_crate, cfg_attrs_by_triple, debug):
    # Do some rounds of mutual resolution; bail when no more changes
    dirty_package_indices = range(len(packages))
    for i in range(_MAX_ROUNDS):
        if hasattr(mctx, "report_progress"):
            mctx.report_progress("Running round %s of dependency/feature resolution" % i)

        dirty_package_indices = _resolve_one_round(packages, dirty_package_indices, cfg_attrs_by_triple, debug)
        if not dirty_package_indices:
            if debug:
                count = _count(feature_resolutions_by_fq_crate)
                print("Got count", count, "in", i + 1, "rounds")
            break
        dirty_package_indices = sorted(dirty_package_indices)

        if i == _MAX_ROUNDS:
            fail("Resolution did not converge! This is likely a bug in rules_rs, please report it to github.com/hermeticbuild/rules_rs")
