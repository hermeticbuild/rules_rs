"""Crate hub resolution."""

load("@bazel_skylib//lib:paths.bzl", "paths")
load("//rs/private:annotations.bzl", "annotation_for")
load("//rs/private:cargo_workspace_graph.bzl", "cargo_toml_fact", "resolve_cargo_workspace_members", "resolve_package_facts", "split_lockfile_packages", _fq_crate = "fq_crate", _normalize_path = "normalize_path")
load("//rs/private:crate_compatibility.bzl", _has_weak_dependency_features = "has_weak_dependency_features", _weak_dependency_feature_requests = "weak_dependency_feature_requests")
load("//rs/private:crate_dependency_order.bzl", _packages_in_dependency_order = "packages_in_dependency_order")
load("//rs/private:crate_metadata.bzl", _git_fact_key = "git_fact_key", _registry_fact_key = "registry_fact_key")
load("//rs/private:toml2json.bzl", "run_toml2json")

def date(ctx, label):
    return
    result = ctx.execute(["gdate", '+"%Y-%m-%d %H:%M:%S.%3N"'])
    print(label, result.stdout)

_date = date

def _label_directory(label):
    idx = label.name.rfind("/")
    if idx == -1:
        return label.package

    return paths.join(label.package, label.name[:idx])

def resolve_hub(
        mctx,
        hub_name,
        annotations,
        cargo_path,
        cargo_lock_path,
        cargo_config,
        workspace_cargo_toml_json,
        all_packages,
        platform_triples,
        validate_lockfile,
        debug,
        generate_lint_config,
        use_legacy_rules_rust_platforms):
    """Resolves a Cargo facade once and returns a reusable materialization plan."""
    _date(mctx, "start")

    mctx.report_progress("Reading workspace metadata")
    result = mctx.execute(
        [cargo_path, "metadata", "--no-deps", "--locked", "--format-version=1", "--quiet"] +
        (["--config", str(mctx.path(cargo_config))] if cargo_config else []),
        working_directory = str(mctx.path(cargo_lock_path).dirname),
    )
    if result.return_code != 0:
        fail(result.stdout + "\n" + result.stderr)
    cargo_metadata = json.decode(result.stdout)

    _date(mctx, "parsed cargo metadata")

    existing_facts = getattr(mctx, "facts", {}) or {}
    facts = {}

    split_packages = split_lockfile_packages(
        hub_name,
        cargo_metadata,
        workspace_cargo_toml_json,
        all_packages,
    )
    packages = split_packages.packages
    workspace_members = split_packages.workspace_members

    # The existing resolver indexes packages by name-version. Detect Cargo
    # graphs that require source-qualified package IDs before any fact or
    # feature maps can silently overwrite an entry.
    package_by_fq = {}
    duplicate_fqs = {}
    for package in packages:
        fq = _fq_crate(package["name"], package["version"])
        if fq in package_by_fq:
            duplicate_fqs[fq] = True
        package_by_fq[fq] = package
    if duplicate_fqs:
        fail("Cargo package graph for hub %s contains multiple packages with the same name and version: %s" % (
            hub_name,
            sorted(duplicate_fqs),
        ))

    mctx.report_progress("Computing dependencies and features")

    facts_by_fq_crate = {}
    for package in packages:
        name = package["name"]
        version = package["version"]
        source = package["source"]
        fact = None

        if source.startswith("sparse+"):
            key = _registry_fact_key(source, name, version)
            encoded_fact = existing_facts.get(key)
            if encoded_fact != None:
                facts[key] = encoded_fact
                fact = json.decode(encoded_fact)
            else:
                package["download_token"].wait()

                # TODO(zbarsky): Should we also dedupe this parsing?
                for line in mctx.read(package["registry_metadata_path"]).strip().split("\n"):
                    if version not in line:
                        continue
                    metadata = json.decode(line)
                    if metadata["vers"] != version:
                        continue

                    features = metadata.get("features") or {}

                    # Crates published with newer Cargo populate this field for `resolver = "2"`.
                    # It can express more nuanced feature dependencies and overrides the keys from legacy features, if present.
                    features.update(metadata.get("features2") or {})

                    dependencies = metadata["deps"]

                    for dep in dependencies:
                        if dep["default_features"]:
                            dep.pop("default_features")
                        if not dep["features"]:
                            dep.pop("features")
                        if dep.get("target", "") == None:
                            dep.pop("target")
                        if dep["kind"] == "normal":
                            dep.pop("kind")
                        if not dep["optional"]:
                            dep.pop("optional")

                    fact = dict(
                        features = features,
                        dependencies = dependencies,
                    )

                    # Nest a serialized JSON since max path depth is 5.
                    facts[key] = json.encode(fact)
                    break

                if fact == None:
                    fail("Registry metadata for %s did not contain crate %s %s" % (
                        source,
                        name,
                        version,
                    ))
        elif source.startswith("path+"):
            # Always re-read a path dependency's Cargo.toml instead of using cached facts.
            # Path dependencies are local, and Cargo.toml can change features or
            # dependencies without changing Cargo.lock, causing stale resolution.
            # Do not return path dependency facts for storage in MODULE.bazel.lock.
            # Watch Cargo.toml so Bazel re-runs the extension when Cargo.toml changes.
            cargo_toml_path = paths.join(package["local_path"], "Cargo.toml")
            mctx.watch(mctx.path(cargo_toml_path))
            annotation = annotation_for(annotations, name, package["version"], hub_name)
            cargo_toml_json = run_toml2json(mctx, cargo_toml_path)
            fact = cargo_toml_fact(cargo_toml_json, {})

            package["strip_prefix"] = fact.get("strip_prefix", "")
        elif source.startswith("git+"):
            annotation = annotation_for(annotations, name, package["version"], hub_name)
            key = _git_fact_key(
                source,
                name,
                version,
                annotation,
                package.get("strip_prefix"),
            )
            encoded_fact = existing_facts.get(key)
            if encoded_fact != None:
                facts[key] = encoded_fact
                fact = json.decode(encoded_fact)
            else:
                info = package.get("member_crate_cargo_toml_info")
                if info:
                    package_workspace_cargo_toml_json = package["workspace_cargo_toml_json"]
                    cargo_toml_json = run_toml2json(mctx, info.path)
                else:
                    cargo_toml_json = package["cargo_toml_json"]
                    package_workspace_cargo_toml_json = package.get("workspace_cargo_toml_json")
                strip_prefix = package.get("strip_prefix", "")

                fact = cargo_toml_fact(cargo_toml_json, package_workspace_cargo_toml_json, strip_prefix = strip_prefix)

                if not fact["dependencies"] and debug:
                    print(name, version, package["source"])

                # Nest a serialized JSON since max path depth is 5.
                facts[key] = json.encode(fact)

            package["strip_prefix"] = fact["strip_prefix"]
        else:
            fail("Unknown source %s for crate %s" % (source, name))

        package["has_weak_dependency_features"] = _has_weak_dependency_features(fact)
        package["weak_dependency_feature_requests"] = _weak_dependency_feature_requests(fact)
        facts_by_fq_crate[_fq_crate(name, version)] = fact

    resolved_facts = resolve_package_facts(packages, facts_by_fq_crate, platform_triples)
    feature_resolutions_by_fq_crate = resolved_facts.feature_resolutions_by_fq_crate
    versions_by_name = resolved_facts.versions_by_name

    # Only files in the current Bazel workspace can/should be watched, so check where our manifests are located.
    watch_manifests = cargo_lock_path.repo_name == ""

    workspace_resolution = resolve_cargo_workspace_members(
        mctx,
        cargo_metadata = cargo_metadata,
        packages = packages,
        workspace_members = workspace_members,
        versions_by_name = versions_by_name,
        feature_resolutions_by_fq_crate = feature_resolutions_by_fq_crate,
        annotations = annotations,
        platform_triples = platform_triples,
        materialize_workspace_members = False,
        validate_lockfile = validate_lockfile,
        debug = debug,
        dep_label_prefix = "@%s//:" % hub_name,
        watch_manifests = watch_manifests,
        use_legacy_rules_rust_platforms = use_legacy_rules_rust_platforms,
    )
    cfg_match_cache = workspace_resolution.cfg_match_cache
    platform_cfg_attrs = workspace_resolution.platform_cfg_attrs
    workspace_dep_labels_by_triple = workspace_resolution.workspace_dep_labels_by_triple
    workspace_dep_versions_by_name = workspace_resolution.workspace_dep_versions_by_name

    for package in packages:
        feature_resolutions = feature_resolutions_by_fq_crate[_fq_crate(package["name"], package["version"])]
        package["has_feature_sensitive_target_dependencies"] = any([
            dep.get("feature_sensitive", False)
            for dep in feature_resolutions.possible_deps
        ])

    _date(mctx, "set up initial deps!")

    packages = _packages_in_dependency_order(
        packages,
        feature_resolutions_by_fq_crate,
        hub_name,
    )

    repo_root = _normalize_path(cargo_metadata["workspace_root"])
    workspace_package = _label_directory(cargo_lock_path)

    return {
        "annotations": annotations,
        "cargo_lock_path": cargo_lock_path,
        "cargo_metadata": cargo_metadata,
        "cfg_match_cache": cfg_match_cache,
        "debug": debug,
        "facts": facts,
        "feature_resolutions_by_fq_crate": feature_resolutions_by_fq_crate,
        "generate_lint_config": generate_lint_config,
        "hub_name": hub_name,
        "package_by_fq": package_by_fq,
        "packages": packages,
        "platform_cfg_attrs": platform_cfg_attrs,
        "platform_triples": platform_triples,
        "repo_root": repo_root,
        "use_legacy_rules_rust_platforms": use_legacy_rules_rust_platforms,
        "versions_by_name": versions_by_name,
        "workspace_cargo_toml_json": workspace_cargo_toml_json,
        "workspace_dep_labels_by_triple": workspace_dep_labels_by_triple,
        "workspace_dep_versions_by_name": workspace_dep_versions_by_name,
        "workspace_package": workspace_package,
    }

_resolve_hub = resolve_hub
