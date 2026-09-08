"""Crate compatibility."""

load("//rs/private:crate_identity.bzl", "normalize_git_remote")
load("//rs/private:crate_metadata.bzl", "git_checkout_fingerprint")
load("//rs/private:downloader.bzl", "parse_git_url")
load("//rs/private:repository_utils.bzl", "COMMON_CRATE_ATTR_POLICIES", "RUST_CRATE_ATTR_POLICIES")

def has_weak_dependency_features(fact):
    """Whether a Cargo fact contains weak dependency feature syntax."""
    for feature_members in fact.get("features", {}).values():
        for member in feature_members:
            if "?/" in member:
                return True
    return False

def weak_dependency_feature_requests(fact):
    """Returns weak dependency requests grouped by dependency and feature.

    Each encoded entry contains the dependency name, requested dependency
    feature, and every local feature that can issue that request. Keeping the
    owners grouped lets the coalescer recognize when an independently resolved
    occurrence has already made the request live through a different owner.
    """
    owners_by_request = {}
    for owner, feature_members in fact.get("features", {}).items():
        for member in feature_members:
            separator = member.find("?/")
            if separator == -1:
                continue
            request = json.encode([member[:separator], member[separator + 2:]])
            owners_by_request.setdefault(request, set()).add(owner)

    return [
        json.encode(json.decode(request) + [sorted(owners_by_request[request])])
        for request in sorted(owners_by_request)
    ]

_COMPATIBILITY_SCHEMA_VERSION = 1

_EXACT_RECORD_KEYS = sorted([
    "crate_rule",
    "git_checkout",
    "has_feature_sensitive_target_dependencies",
    "has_weak_dependency_features",
    "source",
    "weak_dependency_feature_requests",
] + [
    key
    for key, policy in COMMON_CRATE_ATTR_POLICIES.items()
    if policy == "exact"
])

_UNION_RECORD_KEYS = sorted([
    key
    for policies in [RUST_CRATE_ATTR_POLICIES, COMMON_CRATE_ATTR_POLICIES]
    for key, policy in policies.items()
    if policy == "union"
])

_HUB_LOCAL_RECORD_KEYS = sorted([
    key
    for key, policy in RUST_CRATE_ATTR_POLICIES.items()
    if policy == "hub_local"
])

_EXACT_CRATE_RULE_KEYS = sorted([
    key
    for key, policy in RUST_CRATE_ATTR_POLICIES.items()
    if policy == "exact"
])

def _validate_record_keys(section, expected, name):
    actual = sorted(section.keys())
    if actual != expected:
        fail("Crate coalescing compatibility schema %s keys must be %s, got %s" % (name, expected, actual))

def validate_compilation_fingerprint(fingerprint):
    """Fails closed when a compatibility input is missing or unclassified."""
    _validate_record_keys(fingerprint, ["exact", "hub_local", "schema_version", "union"], "record")
    if fingerprint["schema_version"] != _COMPATIBILITY_SCHEMA_VERSION:
        fail("Unsupported crate coalescing compatibility schema version %s" % fingerprint["schema_version"])
    _validate_record_keys(fingerprint["exact"], _EXACT_RECORD_KEYS, "exact")
    _validate_record_keys(fingerprint["exact"]["crate_rule"], _EXACT_CRATE_RULE_KEYS, "exact.crate_rule")
    _validate_record_keys(fingerprint["union"], _UNION_RECORD_KEYS, "union")
    _validate_record_keys(fingerprint["hub_local"], _HUB_LOCAL_RECORD_KEYS, "hub_local")

def compilation_fingerprint(package, annotation, kwargs, platform_triples):
    """Builds a validated, fail-closed compatibility record."""
    source = package["source"]
    git_checkout = None
    if source.startswith("git+"):
        remote, commit = parse_git_url(source)
        source = "git+%s#%s" % (normalize_git_remote(remote), commit)
        git_checkout = git_checkout_fingerprint(annotation)

    expected_kwargs = sorted(RUST_CRATE_ATTR_POLICIES.keys())
    actual_kwargs = sorted(kwargs.keys())
    if actual_kwargs != expected_kwargs:
        fail("coalesced crate kwargs must classify every rust_crate attr; expected %s, got %s" % (expected_kwargs, actual_kwargs))

    exact_rule = {}
    union = {"gen_binaries": sorted(set(annotation.gen_binaries))}
    hub_local = {}
    for key, policy in RUST_CRATE_ATTR_POLICIES.items():
        value = kwargs[key]
        if key == "platform_triples":
            value = sorted(set(platform_triples))
        if policy == "exact":
            exact_rule[key] = value
        elif policy == "union":
            union[key] = value
        elif policy == "hub_local":
            hub_local[key] = value
        else:
            fail("Unknown crate coalescing policy %s for %s" % (policy, key))

    fingerprint = {
        "schema_version": _COMPATIBILITY_SCHEMA_VERSION,
        "exact": {
            "additive_build_file": annotation.additive_build_file,
            "additive_build_file_content": annotation.additive_build_file_content,
            "crate_rule": exact_rule,
            "git_checkout": git_checkout,
            "has_feature_sensitive_target_dependencies": package.get("has_feature_sensitive_target_dependencies", False),
            "has_weak_dependency_features": package.get("has_weak_dependency_features", False),
            "patch_args": annotation.patch_args,
            "patch_cmds": [],
            "patch_cmds_win": [],
            "patch_strip": 0,
            "patch_tool": annotation.patch_tool or "",
            "patches": [str(patch) for patch in annotation.patches],
            "source": source,
            "strip_prefix": package.get("strip_prefix"),
            "weak_dependency_feature_requests": package.get("weak_dependency_feature_requests", []),
        },
        "union": union,
        "hub_local": hub_local,
    }
    validate_compilation_fingerprint(fingerprint)
    return fingerprint

def _union(values_a, values_b):
    return sorted(set(values_a + values_b))

def _merge_selects(first, second):
    return {
        key: _union(first.get(key, []), second.get(key, []))
        for key in sorted(set(first.keys() + second.keys()))
    }

def _label_key(label):
    return str(label)

def _extern_name(label, aliases):
    target = _label_key(label)
    alias = aliases.get(target)
    if alias != None:
        return alias
    return target.rsplit(":", 1)[-1].replace("-", "_")

def _dependency_targets(direct, select):
    targets = {_label_key(label): True for label in direct}
    for labels in select.values():
        for label in labels:
            targets[_label_key(label)] = True
    return targets

def _aliases_preserve_dependency_names(merged, original, dependency_targets):
    for target in dependency_targets:
        if _extern_name(target, merged) != _extern_name(target, original):
            return False
    return True

def _dependency_set_is_valid(labels, aliases):
    targets_by_extern = {}
    externs_by_target = {}
    for label in labels:
        target = _label_key(label)
        extern_name = _extern_name(target, aliases)
        previous_target = targets_by_extern.get(extern_name)
        if previous_target != None and previous_target != target:
            return False
        previous_extern = externs_by_target.get(target)
        if previous_extern != None and previous_extern != extern_name:
            return False
        targets_by_extern[extern_name] = target
        externs_by_target[target] = extern_name
    return True

def _merge_dependency_selects(direct, first, second, merged_aliases):
    # Unconditional annotation dependencies and one selected branch are active
    # together. Check them as one extern namespace rather than checking only the
    # selected labels in isolation.
    if not _dependency_set_is_valid(direct, merged_aliases):
        return None

    direct_targets = {_label_key(label): True for label in direct}
    merged = {}
    for key in sorted(set(first.keys() + second.keys())):
        selected = {}
        for label in first.get(key, []) + second.get(key, []):
            selected[_label_key(label)] = True

        if not _dependency_set_is_valid(
            direct + sorted(selected),
            merged_aliases,
        ):
            return None

        # Avoid emitting a conditional duplicate of an unconditional target.
        merged[key] = sorted([
            target
            for target in selected
            if target not in direct_targets
        ])
    return merged

def _merge_aliases(first, second):
    merged = {_label_key(target): alias for target, alias in first.items()}
    alias_targets = {alias: _label_key(target) for target, alias in first.items()}
    for target, alias in second.items():
        target = _label_key(target)
        previous_target = alias_targets.get(alias)
        if previous_target != None and previous_target != target:
            return None
        previous_alias = merged.get(target)
        if previous_alias != None and previous_alias != alias:
            return None
        merged[target] = alias
        alias_targets[alias] = target
    return merged

def effective_platform_domain(triple, use_legacy_rules_rust_platforms):
    if use_legacy_rules_rust_platforms:
        return triple.replace("-musl", "-gnu").replace("-gnullvm", "-msvc")
    return triple

_effective_platform_domain = effective_platform_domain

def _effective_weak_closures(fingerprint):
    """Expands a weak-feature fingerprint into effective select domains."""
    rule = fingerprint["exact"]["crate_rule"]
    union = fingerprint["union"]
    triples_by_domain = {}
    for triple in union["platform_triples"]:
        domain = _effective_platform_domain(
            triple,
            rule["use_legacy_rules_rust_platforms"],
        )
        triples_by_domain.setdefault(domain, []).append(triple)

    closures = {}
    for domain, triples in triples_by_domain.items():
        features = list(union["crate_features"])
        deps = list(rule["deps"])
        build_deps = list(rule["build_script_deps"])
        for triple in triples:
            features += union["crate_features_select"].get(triple, [])
            deps += union["deps_select"].get(triple, [])
            build_deps += union["build_script_deps_select"].get(triple, [])
        closures[domain] = {
            "features": _union([], features),
            "deps": sorted(set([_label_key(dep) for dep in deps])),
            "build_deps": sorted(set([_label_key(dep) for dep in build_deps])),
        }
    return closures

def _feature_closure_mismatches(first, second):
    """Returns overlapping domains whose enabled feature closures differ."""
    first_closures = _effective_weak_closures(first)
    second_closures = _effective_weak_closures(second)
    return [
        {
            "domain": domain,
            "first": first_closures[domain]["features"],
            "second": second_closures[domain]["features"],
        }
        for domain in sorted(set(first_closures.keys()) & set(second_closures.keys()))
        if first_closures[domain]["features"] != second_closures[domain]["features"]
    ]

def _weak_request_state(closure, encoded_request):
    dep_name, _, owners = json.decode(encoded_request)
    features = {feature: True for feature in closure["features"]}
    return struct(
        active = dep_name in features or "dep:" + dep_name in features,
        requested = any([owner in features for owner in owners]),
    )

def weak_cross_term_hazards(first, second):
    """Finds weak requests that a feature/dependency union would newly fire."""
    requests = first["exact"]["weak_dependency_feature_requests"]
    if requests != second["exact"]["weak_dependency_feature_requests"]:
        return []

    first_closures = _effective_weak_closures(first)
    second_closures = _effective_weak_closures(second)
    hazards = []
    for domain in sorted(set(first_closures.keys()) & set(second_closures.keys())):
        for request in requests:
            first_state = _weak_request_state(first_closures[domain], request)
            second_state = _weak_request_state(second_closures[domain], request)
            first_supplies_request = first_state.requested and not first_state.active
            second_supplies_activation = second_state.active and not second_state.requested
            second_supplies_request = second_state.requested and not second_state.active
            first_supplies_activation = first_state.active and not first_state.requested
            if (first_supplies_request and second_supplies_activation) or (second_supplies_request and first_supplies_activation):
                dep_name, dep_feature, owners = json.decode(request)
                hazards.append({
                    "dependency": dep_name,
                    "dependency_feature": dep_feature,
                    "domain": domain,
                    "owners": owners,
                })
    return hazards

_weak_cross_term_hazards = weak_cross_term_hazards

def _intersection(values_by_domain, key):
    common = None
    for values in values_by_domain.values():
        current = {value: True for value in values[key]}
        if common == None:
            common = current
        else:
            common = {
                value: True
                for value in common
                if value in current
            }
    return sorted(common.keys()) if common != None else []

def _normalize_weak_closure(first, second):
    """Combines compatible domain closures and returns direct/select encoding."""
    closures = {}
    for fingerprint in [first, second]:
        for domain, closure in _effective_weak_closures(fingerprint).items():
            merged = closures.setdefault(domain, {
                "features": [],
                "deps": [],
                "build_deps": [],
            })
            for key in ["features", "deps", "build_deps"]:
                merged[key] = _union(merged[key], closure[key])

    direct = {
        "features": _intersection(closures, "features"),
        "deps": _intersection(closures, "deps"),
        "build_deps": _intersection(closures, "build_deps"),
    }
    selects = {
        "features": {},
        "deps": {},
        "build_deps": {},
    }
    for domain in sorted(closures):
        for key in selects:
            direct_values = {value: True for value in direct[key]}
            selected = [
                value
                for value in closures[domain][key]
                if value not in direct_values
            ]
            if selected:
                selects[key][domain] = selected
    return direct, selects

def exact_without_weak_closure(fingerprint):
    exact = dict(fingerprint["exact"])
    crate_rule = dict(exact["crate_rule"])
    crate_rule.pop("deps")
    crate_rule.pop("build_script_deps")
    exact["crate_rule"] = crate_rule
    return exact

_exact_without_weak_closure = exact_without_weak_closure

def merge_compilation_fingerprints(first, second):
    """Merges explicitly permitted inputs, or returns None if incompatible."""
    validate_compilation_fingerprint(first)
    validate_compilation_fingerprint(second)
    weak = (
        first["exact"]["has_weak_dependency_features"] and
        second["exact"]["has_weak_dependency_features"]
    )
    feature_sensitive = (
        first["exact"]["has_feature_sensitive_target_dependencies"] and
        second["exact"]["has_feature_sensitive_target_dependencies"]
    )
    if weak or feature_sensitive:
        if _exact_without_weak_closure(first) != _exact_without_weak_closure(second):
            return None
    elif first["exact"] != second["exact"]:
        return None

    first_union = first["union"]
    second_union = second["union"]

    # Reject only a weak request that is dormant in one independently resolved
    # occurrence and would meet activation supplied solely by another. If the
    # request is already live where the dependency is active, its propagation
    # is already represented in that hub's completed child closure.
    weak_direct = None
    weak_selects = None
    if weak:
        if _weak_cross_term_hazards(first, second):
            return None
        weak_direct, weak_selects = _normalize_weak_closure(first, second)

    # cfg(feature = ...) dependency predicates have the same union cross-term,
    # but the fingerprint does not retain their ASTs. Fail closed unless every
    # overlapping effective domain has the same completed feature closure.
    if feature_sensitive and _feature_closure_mismatches(first, second):
        return None

    aliases = _merge_aliases(first_union["aliases"], second_union["aliases"])
    if aliases == None:
        return None

    first_rule = first["exact"]["crate_rule"]
    second_rule = second["exact"]["crate_rule"]
    merged_deps = weak_direct["deps"] if weak else first_rule["deps"]
    merged_build_deps = weak_direct["build_deps"] if weak else first_rule["build_script_deps"]
    first_dependency_targets = _dependency_targets(
        first_rule["build_script_deps"],
        first_union["build_script_deps_select"],
    ) | _dependency_targets(
        first_rule["deps"],
        first_union["deps_select"],
    )
    second_dependency_targets = _dependency_targets(
        second_rule["build_script_deps"],
        second_union["build_script_deps_select"],
    ) | _dependency_targets(
        second_rule["deps"],
        second_union["deps_select"],
    )
    if not _aliases_preserve_dependency_names(aliases, first_union["aliases"], first_dependency_targets) or not _aliases_preserve_dependency_names(aliases, second_union["aliases"], second_dependency_targets):
        return None

    dependency_selects = {
        "build_script_deps_select": weak_selects["build_deps"] if weak else _merge_dependency_selects(
            merged_build_deps,
            first_union["build_script_deps_select"],
            second_union["build_script_deps_select"],
            aliases,
        ),
        "deps_select": weak_selects["deps"] if weak else _merge_dependency_selects(
            merged_deps,
            first_union["deps_select"],
            second_union["deps_select"],
            aliases,
        ),
    }
    if None in dependency_selects.values():
        return None
    for direct, selected in [
        (merged_deps, dependency_selects["deps_select"]),
        (merged_build_deps, dependency_selects["build_script_deps_select"]),
    ]:
        if not _dependency_set_is_valid(direct, aliases):
            return None
        for branch in selected.values():
            if not _dependency_set_is_valid(direct + branch, aliases):
                return None

    merged_union = {
        "aliases": aliases,
        "build_script_deps_select": dependency_selects["build_script_deps_select"],
        "crate_features": weak_direct["features"] if weak else _union(first_union["crate_features"], second_union["crate_features"]),
        "crate_features_select": weak_selects["features"] if weak else _merge_selects(first_union["crate_features_select"], second_union["crate_features_select"]),
        "deps_select": dependency_selects["deps_select"],
        "gen_binaries": _union(first_union["gen_binaries"], second_union["gen_binaries"]),
        "platform_triples": _union(first_union["platform_triples"], second_union["platform_triples"]),
    }
    merged_exact = first["exact"]
    if weak:
        merged_exact = dict(merged_exact)
        merged_rule = dict(merged_exact["crate_rule"])
        merged_rule["deps"] = merged_deps
        merged_rule["build_script_deps"] = merged_build_deps
        merged_exact["crate_rule"] = merged_rule
    merged = {
        "schema_version": _COMPATIBILITY_SCHEMA_VERSION,
        "exact": merged_exact,
        "union": merged_union,
        "hub_local": first["hub_local"],
    }
    validate_compilation_fingerprint(merged)
    return merged
