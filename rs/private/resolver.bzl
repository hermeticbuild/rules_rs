load("//rs/private:cfg_parser.bzl", "cfg_matches_expr_for_cfg_attrs")

# Feature worlds (cargo resolver v2, `resolver_feature_worlds = "split"`):
# target world = normal-dep state, host world = build-dep + proc-macro state.
# Split work items are `package_index * 2 + world` (cheap int set); unified
# mode uses plain package indices, world fixed to target.
_WORLD_TARGET = 0
_WORLD_HOST = 1

def ensure_host_state(feature_resolutions):
    """Lazily materializes host-world state, only for crates the host world
    reaches (keeps unified mode untouched). Copies in pending feature seeds."""
    host = feature_resolutions.host
    state = host["state"]
    if state == None:
        triples = feature_resolutions.features_enabled.keys()
        state = {
            "active": {triple: False for triple in triples},
            "aliases": {},
            "build_deps": {triple: set() for triple in triples},
            "deps": {triple: set() for triple in triples},
            "features_enabled": {triple: set() for triple in triples},
        }
        pending = host.get("pending_features")
        if pending != None:
            for triple, features in pending.items():
                state["features_enabled"][triple].update(features)
        host["state"] = state
    return state

def seed_pending_host_features(feature_resolutions, triple, features):
    """Seeds features into a crate's host world WITHOUT activating it.

    For feature-amphibious edges (member [build-dependencies]): the edge stays
    target-world for activation/labels (members are world boundaries), but its
    features must also reach the host instance so crates shared by member build
    scripts and proc-macro/build-dep trees agree across worlds (cargo resolver
    v2 puts both edges in the host world).

    Before host state exists, seeds go to the same pending_features container
    annotations use. Returns True iff the live host feature set grew at a
    host-active triple (the only case the caller must re-dirty the host item).
    """
    host = feature_resolutions.host
    state = host["state"]
    if state == None:
        pending = host.get("pending_features")
        if pending == None:
            pending = {t: set() for t in feature_resolutions.features_enabled.keys()}
            host["pending_features"] = pending
        pending[triple].update(features)
        return False

    triple_features = state["features_enabled"][triple]
    prev_length = len(triple_features)
    triple_features.update(features)
    return prev_length != len(triple_features) and state["active"][triple]

def _count(feature_resolutions_by_fq_crate):
    n = 0
    for feature_resolutions in feature_resolutions_by_fq_crate.values():
        for features in feature_resolutions.features_enabled.values():
            n += len(features)

        for build_deps in feature_resolutions.build_deps.values():
            n += len(build_deps)

        for deps in feature_resolutions.deps.values():
            n += len(deps)

        host_state = feature_resolutions.host["state"]
        if host_state != None:
            for features in host_state["features_enabled"].values():
                n += len(features)

            for build_deps in host_state["build_deps"].values():
                n += len(build_deps)

            for deps in host_state["deps"].values():
                n += len(deps)

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

def _world_features_enabled(feature_resolutions, world):
    if world == _WORLD_HOST:
        return ensure_host_state(feature_resolutions)["features_enabled"]
    return feature_resolutions.features_enabled

def _dep_world(world, kind, feature_resolutions, dep_feature_resolutions):
    # Cargo resolver v2 edge classification, members as world BOUNDARIES:
    # build-dep edges and edges into proc-macro spokes cross to host; other
    # edges stay in the originating world (host-ness sticky down normal chains).
    #
    # Members are gazelle-generated single instances mixing DEP_DATA labels,
    # hand-written `@crates//:x` pins and member-to-member labels, and one
    # action links only ONE instance per crate. So edges into members stay
    # target-world, and member build edges stay target-world too (else E0464) —
    # their features unify into base instances, as in unified mode.
    if dep_feature_resolutions.is_workspace_member:
        return _WORLD_TARGET
    if dep_feature_resolutions.is_proc_macro:
        return _WORLD_HOST
    if kind == "build" and not feature_resolutions.is_workspace_member:
        return _WORLD_HOST
    return world

def _is_amphibious_edge(kind, dep_world, feature_resolutions, dep_feature_resolutions):
    # Member [build-dependencies] onto a plain spoke: target-world edge (the
    # dep_world check excludes proc-macro spokes), consumer is a member, dep is
    # not (members have no host world).
    return (kind == "build" and
            dep_world == _WORLD_TARGET and
            feature_resolutions.is_workspace_member and
            not dep_feature_resolutions.is_workspace_member)

def _queue_or_dirty(item, new_dirty_items, worklist, queued, processed):
    # In-round drain (split): unprocessed items append to this round's worklist
    # (each at most once, bounded by 2 * len(packages)); already-processed
    # items re-dirty into the next round.
    if item in processed:
        new_dirty_items.add(item)
    elif item not in queued:
        queued.add(item)
        worklist.append(item)

def _activate(dep_feature_resolutions, world, triple, new_dirty_items, worklist, queued, processed):
    if world == _WORLD_HOST:
        active = ensure_host_state(dep_feature_resolutions)["active"]
    else:
        active = dep_feature_resolutions.target_active

    if not active[triple]:
        active[triple] = True
        _queue_or_dirty(dep_feature_resolutions.package_index * 2 + world, new_dirty_items, worklist, queued, processed)

def _dep_world_remaining(dep, world):
    # Per-(edge, world) unprocessed-triple sets: an edge done for one world may
    # still need the other, and `dep["target"]` must stay intact for
    # `_dep_target_matches_triple` (unified mode mutates it directly instead).
    remaining_by_world = dep.get("_remaining")
    if remaining_by_world == None:
        remaining_by_world = [None, None]
        dep["_remaining"] = remaining_by_world

    remaining = remaining_by_world[world]
    if remaining == None:
        remaining = set(dep["target"])
        remaining_by_world[world] = remaining
    return remaining

def _resolve_one_round(packages, dirty_items, cfg_attrs_by_triple, debug, split_mode):
    # One body, both modes. Unified is the degenerate case: plain package
    # indices, world fixed to target, no host machinery or activation gating,
    # and direct `dep["target"]` consumption (split uses _remaining + in-round
    # worklist draining).
    new_dirty_items = set()

    worklist = list(dirty_items)
    queued = set(worklist) if split_mode else None
    processed = set() if split_mode else None

    # Bounded in-round drain (no `while` in Starlark): activation is monotone
    # and `queued` admits each item once, so worklist <= 2 * len(packages).
    # Unified mode never appends — a plain iteration over the dirty items.
    for cursor in range(2 * len(packages)):
        if cursor >= len(worklist):
            break
        item = worklist[cursor]

        if split_mode:
            processed.add(item)
            package_index = item // 2
            world = item % 2
        else:
            package_index = item
            world = _WORLD_TARGET

        package = packages[package_index]
        package_changed = False

        feature_resolutions = package["feature_resolutions"]

        if world == _WORLD_HOST:
            host_state = ensure_host_state(feature_resolutions)
            features_enabled = host_state["features_enabled"]
            deps = host_state["deps"]
            build_deps = host_state["build_deps"]
            aliases = host_state["aliases"]
        else:
            features_enabled = feature_resolutions.features_enabled
            deps = feature_resolutions.deps
            build_deps = feature_resolutions.build_deps
            aliases = feature_resolutions.aliases

        if _propagate_feature_enablement(
            new_dirty_items,
            worklist,
            queued,
            processed,
            package,
            world,
            features_enabled,
            feature_resolutions,
            cfg_attrs_by_triple,
            debug,
            split_mode,
        ):
            package_changed = True

        # Propagate features across currently enabled dependencies.
        for dep in feature_resolutions.possible_deps:
            bazel_target = dep.get("bazel_target")
            if not bazel_target:
                continue

            if split_mode:
                remaining = _dep_world_remaining(dep, world)
                if not remaining:
                    continue

            kind = dep.get("kind", "normal")

            dep_feature_resolutions = dep["feature_resolutions"]
            dep_world = _dep_world(world, kind, feature_resolutions, dep_feature_resolutions) if split_mode else _WORLD_TARGET

            has_alias = "package" in dep
            dep_name = dep["name"]
            prefixed_dep_alias = "dep:" + dep_name
            optional = dep.get("optional", False)

            # Split: work items exist only for edge-ACTIVATED (package, world)
            # pairs — the gating that stops a host-only crate leaking features
            # into its deps' target sets. Within an item, all cfg-matched
            # triples are processed (as in unified mode), so a crate reachable
            # only behind cfg(linux) edges still renders a buildable view if
            # configured on darwin (public hub aliases, hand-written refs).
            if dep.get("feature_sensitive"):
                match = set([
                    triple
                    for triple in (remaining if split_mode else dep["target"])
                    if _dep_target_matches_triple(dep, triple, features_enabled[triple], cfg_attrs_by_triple)
                ])
            elif split_mode:
                match = remaining
            else:
                # NOT a copy: the consumption below mutates dep["target"].
                match = dep["target"]

            to_remove = None
            for triple in match:
                if optional:
                    features_for_triple = features_enabled[triple]
                    if dep_name not in features_for_triple and prefixed_dep_alias not in features_for_triple:
                        continue

                triple_deps = deps[triple] if kind == "normal" else build_deps[triple]
                if package_changed or bazel_target not in triple_deps:
                    package_changed = True
                    triple_deps.add(bazel_target)

                if has_alias:
                    aliases[bazel_target] = dep_name.replace("-", "_")

                if split_mode:
                    _activate(dep_feature_resolutions, dep_world, triple, new_dirty_items, worklist, queued, processed)

                dep_features = dep.get("features")
                if dep_features:
                    triple_features = _world_features_enabled(dep_feature_resolutions, dep_world)[triple]
                    prev_length = len(triple_features)
                    triple_features.update(dep_features)
                    if prev_length != len(triple_features):
                        if split_mode:
                            _queue_or_dirty(dep_feature_resolutions.package_index * 2 + dep_world, new_dirty_items, worklist, queued, processed)
                        else:
                            new_dirty_items.add(dep_feature_resolutions.package_index)

                    # Member build edges are feature-AMPHIBIOUS: target-world
                    # for activation/labels, but features also reach the dep's
                    # host instance so shared crates agree across worlds.
                    if split_mode and _is_amphibious_edge(kind, dep_world, feature_resolutions, dep_feature_resolutions):
                        if seed_pending_host_features(dep_feature_resolutions, triple, dep_features):
                            _queue_or_dirty(dep_feature_resolutions.package_index * 2 + _WORLD_HOST, new_dirty_items, worklist, queued, processed)
                if not to_remove:
                    to_remove = set()
                to_remove.add(triple)

            if to_remove:
                if split_mode:
                    remaining.difference_update(to_remove)
                elif len(to_remove) == len(match):
                    dep["bazel_target"] = None
                else:
                    match.difference_update(to_remove)

        if package_changed:
            new_dirty_items.add(item)

    if len(worklist) > 2 * len(packages):
        fail("rules_rs internal error: split-mode worklist exceeded the activation bound")

    return new_dirty_items

def _propagate_feature_enablement(
        new_dirty_items,
        worklist,
        queued,
        processed,
        package,
        world,
        features_enabled,
        feature_resolutions,
        cfg_attrs_by_triple,
        debug,
        split_mode):
    package_changed = False
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

                optional_marker = False
                if dep_name[-1] == "?":
                    optional_marker = True
                    dep_name = dep_name[:-1]

                found = False
                any_optional = False

                # Split iterates ALL entries matching the name (a crate often
                # lists the same package under [dependencies] and
                # [build-dependencies]); each forwards `dep_feature` into its
                # own world. Unified keeps the historical first-match `break`
                # for byte-identical output; fixing it there is a follow-up.
                for dep in feature_resolutions.possible_deps:
                    if dep_name != dep["name"]:
                        continue
                    if not _dep_target_matches_triple(dep, triple, feature_set, cfg_attrs_by_triple):
                        continue

                    found = True
                    dep_optional = dep.get("optional", False)
                    if dep_optional:
                        any_optional = True

                    if not optional_marker or not dep_optional or dep_name in feature_set or ("dep:" + dep_name) in feature_set:
                        dep_feature_resolutions = dep["feature_resolutions"]
                        dep_kind = dep.get("kind", "normal")
                        dep_world = _dep_world(world, dep_kind, feature_resolutions, dep_feature_resolutions) if split_mode else _WORLD_TARGET
                        triple_features = _world_features_enabled(dep_feature_resolutions, dep_world)[triple]
                        if dep_feature not in triple_features:
                            triple_features.add(dep_feature)
                            if split_mode:
                                _queue_or_dirty(dep_feature_resolutions.package_index * 2 + dep_world, new_dirty_items, worklist, queued, processed)
                            else:
                                new_dirty_items.add(dep_feature_resolutions.package_index)

                        # See the edge loop: member build-dep entries forward
                        # into the host world too (feature-amphibious).
                        if split_mode and _is_amphibious_edge(dep_kind, dep_world, feature_resolutions, dep_feature_resolutions):
                            if seed_pending_host_features(dep_feature_resolutions, triple, [dep_feature]):
                                _queue_or_dirty(dep_feature_resolutions.package_index * 2 + _WORLD_HOST, new_dirty_items, worklist, queued, processed)

                    if not split_mode:
                        break

                # Only optional deps need to be explicitly enabled when a subfeature is toggled.
                if any_optional and (not optional_marker) and dep_name not in feature_set:
                    package_changed = True
                    feature_set.add(dep_name)

                if not found and debug:
                    print("Skipping enabling subfeature", feature, "for", package["name"], "@", package["version"], "it's not a dep...")

    return package_changed

_MAX_ROUNDS = 50

def resolve(mctx, packages, feature_resolutions_by_fq_crate, cfg_attrs_by_triple, debug, split = False):
    """Runs the dependency/feature fixpoint. Returns the number of rounds used."""
    if split:
        # Edge-activation-driven: only items marked active by member seeding
        # start dirty; round 0's in-round drain pulls the rest of the reachable
        # frontier, so round count tracks feature-implication depth, not graph
        # depth.
        dirty_items = []
        for package_index in range(len(packages)):
            feature_resolutions = packages[package_index]["feature_resolutions"]
            for is_active in feature_resolutions.target_active.values():
                if is_active:
                    dirty_items.append(package_index * 2)
                    break

            host_state = feature_resolutions.host["state"]
            if host_state != None:
                for is_active in host_state["active"].values():
                    if is_active:
                        dirty_items.append(package_index * 2 + _WORLD_HOST)
                        break
    else:
        # Do some rounds of mutual resolution; bail when no more changes
        dirty_items = range(len(packages))

    for i in range(_MAX_ROUNDS):
        mctx.report_progress("Running round %s of dependency/feature resolution" % i)
        if debug and split:
            print("split-worlds round", i, "work items:", len(dirty_items))

        dirty_items = _resolve_one_round(packages, dirty_items, cfg_attrs_by_triple, debug, split)
        if not dirty_items:
            if debug:
                count = _count(feature_resolutions_by_fq_crate)
                print("Got count", count, "in", i + 1, "rounds")
            return i + 1
        dirty_items = sorted(dirty_items)

        if i == _MAX_ROUNDS - 1:
            fail("Resolution did not converge! This is likely a bug in rules_rs, please report it to github.com/hermeticbuild/rules_rs")
    return _MAX_ROUNDS
