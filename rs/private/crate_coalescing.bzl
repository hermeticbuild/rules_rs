"""Crate coalescing."""

load("//rs/private:crate_compatibility.bzl", "merge_compilation_fingerprints", "validate_compilation_fingerprint", _effective_platform_domain = "effective_platform_domain", _exact_without_weak_closure = "exact_without_weak_closure", _weak_cross_term_hazards = "weak_cross_term_hazards")
load("//rs/private:crate_identity.bzl", "canonical_spoke_repo", "package_identity", "spoke_repo")

def _assignment_key(hub_name, identity):
    return json.encode([hub_name, identity])

def _dependency_repo_name(label):
    label = str(label)
    if label.startswith("@@"):
        label = label[2:]
    elif label.startswith("@"):
        label = label[1:]
    else:
        return None
    separator = label.find("//")
    if separator == -1:
        return None
    return label[:separator]

def _fingerprint_platform_domains(fingerprint):
    rule = fingerprint["exact"]["crate_rule"]
    return {
        _effective_platform_domain(triple, rule["use_legacy_rules_rust_platforms"]): True
        for triple in fingerprint["union"]["platform_triples"]
    }

def _fingerprint_dependency_repository_domains(fingerprint):
    rule = fingerprint["exact"]["crate_rule"]
    union = fingerprint["union"]
    repositories = {}
    all_domains = _fingerprint_platform_domains(fingerprint)
    for label in rule["deps"] + rule["build_script_deps"]:
        repo_name = _dependency_repo_name(label)
        if repo_name:
            repositories[repo_name] = dict(all_domains)
    for select_key in ["deps_select", "build_script_deps_select"]:
        for domain, labels in union[select_key].items():
            domain = _effective_platform_domain(domain, rule["use_legacy_rules_rust_platforms"])
            for label in labels:
                repo_name = _dependency_repo_name(label)
                if repo_name:
                    domains = repositories.get(repo_name)
                    if domains == None:
                        domains = {}
                        repositories[repo_name] = domains
                    domains[domain] = True
    return repositories

def _domains_overlap(first, second):
    for domain in first:
        if domain in second:
            return True
    return False

def _dependency_classes_match_occurrences(coalescer, fingerprint, occurrences):
    for repo_name, dependency_domains in _fingerprint_dependency_repository_domains(fingerprint).items():
        identity = coalescer["identities_by_repo"].get(repo_name)
        if identity == None:
            continue
        for occurrence in occurrences:
            if not _domains_overlap(dependency_domains, _fingerprint_platform_domains(occurrence["fingerprint"])):
                continue
            hub_name = occurrence["hub_name"]
            assignment = coalescer["assignments"].get(_assignment_key(hub_name, identity))
            if assignment != None and assignment["repo_name"] != repo_name:
                return False
    return True

def _record_repo_identity(coalescer, repo_name, identity):
    previous_identity = coalescer["identities_by_repo"].get(repo_name)
    if previous_identity != None and previous_identity != identity:
        fail("Cargo package identities %s and %s encode to the same canonical repository %s" % (
            previous_identity,
            identity,
            repo_name,
        ))
    coalescer["identities_by_repo"][repo_name] = identity

def finalize_coalescer(coalescer):
    """Freezes collection and prepares compatibility classes for creation."""
    if coalescer.get("phase") != None:
        fail("Cannot finalize a crate coalescer more than once")
    coalescer["phase"] = "create"
    coalescer["created"] = {}

def coalesced_compilation_fingerprint(coalescer, package, package_path, hub_name, fallback):
    """Returns the finalized fingerprint for an occurrence's compatibility class."""
    identity = package_identity(package, package_path)
    if not identity or coalescer.get("phase") != "create":
        return fallback

    assignment_key = _assignment_key(hub_name, identity)
    assignment = coalescer["assignments"].get(assignment_key)
    package_record = coalescer["packages"].get(identity)
    if assignment == None or package_record == None:
        fail("Missing finalized crate coalescing assignment for %s" % assignment_key)

    return package_record["classes"][assignment["class_index"]]["fingerprint"]

def coalesced_compilation_kwargs(coalescer, package, package_path, hub_name, fallback):
    """Returns the finalized kwargs for an occurrence's compatibility class."""
    if not package_identity(package, package_path) or coalescer.get("phase") != "create":
        return fallback

    fingerprint = coalesced_compilation_fingerprint(
        coalescer,
        package,
        package_path,
        hub_name,
        {"kwargs": fallback},
    )
    validate_compilation_fingerprint(fingerprint)
    kwargs = dict(fingerprint["exact"]["crate_rule"])
    kwargs.update(fingerprint["union"])
    kwargs.update(fingerprint["hub_local"])
    kwargs["hub_name"] = fallback.get("hub_name", hub_name)
    kwargs.pop("gen_binaries")
    return kwargs

def coalesce_spoke(coalescer, package, package_path, hub_name, fingerprint):
    """Returns (repository name, compatibility-class index, create repository)."""
    identity = package_identity(package, package_path)
    if not identity:
        repo_name = spoke_repo(hub_name, package["name"], package["version"])
        if coalescer.get("phase") == "create":
            if repo_name in coalescer["created"]:
                return repo_name, None, False
            coalescer["created"][repo_name] = True
        return repo_name, None, True

    assignment_key = _assignment_key(hub_name, identity)
    phase = coalescer.get("phase")
    if phase == "create":
        assignment = coalescer["assignments"][assignment_key]
        repo_name = assignment["repo_name"]
        if repo_name in coalescer["created"]:
            return repo_name, assignment["class_index"], False
        coalescer["created"][repo_name] = True
        return repo_name, assignment["class_index"], True
    if phase != None:
        fail("Unknown crate coalescer phase %s" % phase)

    checksum = package.get("checksum")
    package_record = coalescer["packages"].get(identity)
    if not package_record:
        package_record = {
            "checksum": checksum,
            "classes": [],
            "first_hub": hub_name,
        }
        coalescer["packages"][identity] = package_record
    elif package_record["checksum"] != checksum:
        fail("""Conflicting Cargo registry checksums for {identity}:
  {first_hub}: {first_checksum}
  {second_hub}: {second_checksum}
Align the Cargo.lock files before combining these Bazel modules.""".format(
            identity = identity,
            first_hub = package_record["first_hub"],
            first_checksum = package_record["checksum"],
            second_hub = hub_name,
            second_checksum = checksum,
        ))

    classes = package_record["classes"]
    weak_mismatch_diagnostics = []
    for class_index in range(len(classes)):
        compatibility_class = classes[class_index]
        merged_fingerprint = merge_compilation_fingerprints(
            compatibility_class["fingerprint"],
            fingerprint,
        )
        if (
            merged_fingerprint != None and
            not _dependency_classes_match_occurrences(
                coalescer,
                merged_fingerprint,
                compatibility_class["occurrences"] + [{
                    "fingerprint": fingerprint,
                    "hub_name": hub_name,
                }],
            )
        ):
            merged_fingerprint = None
        if merged_fingerprint == None:
            first_fingerprint = compatibility_class["fingerprint"]
            if (
                first_fingerprint["exact"]["has_weak_dependency_features"] and
                fingerprint["exact"]["has_weak_dependency_features"] and
                _exact_without_weak_closure(first_fingerprint) == _exact_without_weak_closure(fingerprint)
            ):
                hazards = _weak_cross_term_hazards(first_fingerprint, fingerprint)
                if hazards:
                    weak_mismatch_diagnostics.append((
                        compatibility_class["hubs"],
                        hazards,
                    ))
            continue

        compatibility_class["fingerprint"] = merged_fingerprint
        compatibility_class["hubs"].append(hub_name)
        compatibility_class["occurrences"].append({
            "fingerprint": fingerprint,
            "hub_name": hub_name,
        })
        assignment = {
            "class_index": class_index,
            "repo_name": compatibility_class["repo_name"],
        }
        coalescer["assignments"][assignment_key] = assignment
        return assignment["repo_name"], class_index, False

    for existing_hubs, hazard_records in weak_mismatch_diagnostics:
        print("""Weak dependency feature merge hazard for Cargo package {name} {version} ({source})
  existing class hubs: {existing_hubs}
  compared hub: {second_hub}
  overlapping effective select domains:
{hazards}
Keeping separate crate coalescing compatibility classes.""".format(
            name = package["name"],
            version = package["version"],
            source = package["source"],
            existing_hubs = ", ".join(existing_hubs),
            second_hub = hub_name,
            hazards = "\n".join([
                "    {domain}: {owners} enables {dependency}?/{dependency_feature} while the other occurrence alone activates {dependency}".format(
                    domain = hazard["domain"],
                    owners = hazard["owners"],
                    dependency = hazard["dependency"],
                    dependency_feature = hazard["dependency_feature"],
                )
                for hazard in hazard_records
            ]),
        ))

    class_index = len(classes)
    repo_name = canonical_spoke_repo(package, package_path, class_index)
    _record_repo_identity(coalescer, repo_name, identity)
    classes.append({
        "fingerprint": fingerprint,
        "first_hub": hub_name,
        "hubs": [hub_name],
        "occurrences": [{
            "fingerprint": fingerprint,
            "hub_name": hub_name,
        }],
        "repo_name": repo_name,
    })
    coalescer["assignments"][assignment_key] = {
        "class_index": class_index,
        "repo_name": repo_name,
    }
    return repo_name, class_index, True
