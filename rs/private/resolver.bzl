load("//rs/private:cfg_parser.bzl", "cfg_matches_ast")

def _count(states):
    count = 0
    for state in states:
        resolution = state.resolution
        for by_triple in [resolution.features_enabled, resolution.deps, resolution.build_deps]:
            for items in by_triple.values():
                count += len(items)
    return count

def _cfg_platforms(ast, mask, features, platforms):
    for triple, bit in platforms.bits.items():
        if mask & bit:
            if not cfg_matches_ast(ast, platforms.attrs[triple], lambda name: bool(features.get(name, 0) & bit)):
                mask ^= bit
    return mask

def _enable(state, name, mask, dirty):
    previous = state.features.get(name, 0)
    added = mask & ~previous
    if not added:
        return
    dirty.add(state.resolution.package_index)
    state.features[name] = previous | added
    implications = state.resolution.possible_features.get(name)
    if implications:
        # Preserve each platform's feature order for cfg(not(feature = "...")).
        state.implications.append((implications, added))

def _resolve_features(state, states, dirty, platforms, debug):
    features = state.features
    for implications, mask in state.implications[:]:
        for implication in implications:
            dep_name, slash, feature = implication.partition("/")
            if not slash:
                _enable(state, implication, mask, dirty)
                continue

            weak = dep_name.endswith("?")
            if weak:
                dep_name = dep_name[:-1]
            unmatched = mask
            for dep in state.deps_by_name.get(dep_name, []):
                matches = unmatched & dep["platforms"]
                if matches and dep.get("feature_cfg"):
                    matches = _cfg_platforms(dep["feature_cfg"], matches, features, platforms)
                if not matches:
                    continue
                unmatched ^= matches
                optional = dep.get("optional")
                if optional and weak:
                    matches &= features.get(dep_name, 0) | features.get("dep:" + dep_name, 0)
                _enable(states[dep["package_index"]], feature, matches, dirty)
                if optional and not weak:
                    _enable(state, dep_name, matches, dirty)
                if not unmatched:
                    break
            if debug and unmatched:
                print("Skipping enabling subfeature", implication, "for", state.package["name"], "@", state.package["version"], "on", [t for t, bit in platforms.bits.items() if unmatched & bit])

def _resolve_dependencies(state, pending, states, dirty, platforms):
    remaining = []
    for dep, mask in pending:
        active = mask
        name = dep["name"]
        if dep.get("optional"):
            active &= state.features.get(name, 0) | state.features.get("dep:" + name, 0)
        if active and dep.get("feature_cfg"):
            active = _cfg_platforms(dep["feature_cfg"], active, state.features, platforms)
        if active != mask:
            remaining.append((dep, mask ^ active))
        if not active:
            continue

        target = dep["bazel_target"]
        output = state.deps if dep.get("kind", "normal") == "normal" else state.build_deps
        output[target] = output.get(target, 0) | active
        if "package" in dep:
            state.resolution.aliases[target] = name.replace("-", "_")
        for feature in dep.get("features", []):
            _enable(states[dep["package_index"]], feature, active, dirty)
    return remaining

def _sorted_by_triple(masks, bits):
    items = sorted(masks)
    if len(set(masks.values())) == 1:
        mask = masks[items[0]]
        return {triple: items if mask & bit else [] for triple, bit in bits.items()}

    return {
        triple: [item for item in items if masks[item] & bit]
        for triple, bit in bits.items()
    }

_MAX_ROUNDS = 200

def resolve(mctx, packages, platforms, debug):
    # Each feature maps to the platforms that enable it. Propagate those
    # platforms together, then expand them into the per-triple repository attributes.
    platform_bits = platforms.bits
    states = []
    pending = []
    dirty = set(range(len(packages)))
    for package in packages:
        resolution = package["feature_resolutions"]

        deps_by_name = {}
        dependencies = []
        for dep in resolution.possible_deps:
            if "package_index" not in dep:
                continue
            dependencies.append((dep, dep["platforms"]))
            deps_by_name.setdefault(dep["name"], []).append(dep)
        pending.append(dependencies)
        state = struct(
            package = package,
            resolution = resolution,
            features = {},
            implications = [],
            deps = {},
            build_deps = {},
            deps_by_name = deps_by_name,
        )
        states.append(state)
        for names, mask in resolution.feature_seeds:
            for name in names:
                _enable(state, name, mask, dirty)

    for i in range(_MAX_ROUNDS):
        if mctx:
            mctx.report_progress("Running round %s of dependency/feature resolution" % i)
        changed = set()
        for index in dirty:
            state = states[index]
            _resolve_features(state, states, changed, platforms, debug)
            if pending[index]:
                pending[index] = _resolve_dependencies(state, pending[index], states, changed, platforms)
        if not changed:
            break
        dirty = sorted(changed)
    if changed:
        fail("Resolution did not converge after %s rounds! This is likely a bug in rules_rs, please report it to github.com/hermeticbuild/rules_rs" % _MAX_ROUNDS)

    for state in states:
        resolution = state.resolution
        resolution.features_enabled.update(_sorted_by_triple(state.features, platform_bits))
        resolution.deps.update(_sorted_by_triple(state.deps, platform_bits))
        resolution.build_deps.update(_sorted_by_triple(state.build_deps, platform_bits))

    if debug:
        print("Got count", _count(states), "in", i + 1, "rounds")
