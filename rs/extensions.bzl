load("@aspect_tools_telemetry_report//:defs.bzl", "TELEMETRY")  # buildifier: disable=load
load("@bazel_lib//lib:repo_utils.bzl", "repo_utils")
load("@bazel_skylib//lib:paths.bzl", "paths")
load("@rs_rust_host_tools//:defs.bzl", "RS_HOST_CARGO_LABEL")
load("//rs/private:annotations.bzl", "annotation_for", "build_annotation_map", "well_known_annotation_snippet_paths")
load("//rs/private:cargo_credentials.bzl", "load_cargo_credentials")
load(
    "//rs/private:cargo_workspace_graph.bzl",
    "platform_label",
    "render_dep_data",
    "render_string_list",
    "resolve_cargo_workspace_members",
    "workspace_dep_data",
    _add_to_dict = "add_to_dict",
    _fq_crate = "fq_crate",
    _new_feature_resolutions = "new_feature_resolutions",
    _normalize_path = "normalize_path",
    _prepare_possible_deps = "prepare_possible_deps",
    _select = "select_items",
)
load("//rs/private:crate_repository.bzl", "crate_repository", "local_crate_repository")
load("//rs/private:downloader.bzl", "download_metadata_for_git_crates", "new_downloader_state", "parse_git_url", "start_crate_registry_downloads", "start_github_downloads")
load("//rs/private:git_cargo_workspace_repository.bzl", "git_cargo_workspace_repository")
load("//rs/private:git_crate_metadata_repository.bzl", "git_crate_metadata_repository")
load("//rs/private:lint_flags.bzl", "cargo_toml_lint_flags")
load("//rs/private:registry_config_repository.bzl", "registry_config_repository")
load("//rs/private:registry_utils.bzl", "CRATES_IO_REGISTRY", "registry_config_repo_name")
load("//rs/private:repository_utils.bzl", "render_select")
load("//rs/private:toml2json.bzl", "run_toml2json")

def _spoke_repo(hub_name, name, version):
    s = "%s__%s-%s" % (hub_name, name, version)
    if "+" in s:
        s = s.replace("+", "-")
    return s

def _external_repo_for_git_source(hub_name, remote, commit):
    return hub_name + "__" + remote.replace("/", "_").replace(":", "_").replace("@", "_") + "_" + commit

def _git_crate_purl(name, version, remote, commit):
    return "pkg:cargo/%s@%s?vcs_url=git+%s@%s" % (name, version, remote, commit)

def _render_ordered_string_list(items):
    """Like _render_string_list but preserves insertion order."""
    return ",\n        ".join(['"%s"' % item for item in items])

def _date(ctx, label):
    return
    result = ctx.execute(["gdate", '+"%Y-%m-%d %H:%M:%S.%3N"'])
    print(label, result.stdout)

def _relative_to_workspace(path, workspace_root):
    normalized_root = _normalize_path(workspace_root)
    normalized_path = _normalize_path(path)

    if not paths.is_absolute(normalized_path):
        normalized_path = _normalize_path(paths.normalize(paths.join(normalized_root, normalized_path)))

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

def _label_directory(label):
    idx = label.name.rfind("/")
    if idx == -1:
        return label.package

    return paths.join(label.package, label.name[:idx])

def _git_crate_package_path(annotation, strip_prefix):
    workspace_dir = annotation.workspace_cargo_toml.removesuffix("Cargo.toml").removesuffix("/")
    crate_dir = (strip_prefix or "").removeprefix("./").removesuffix("/")

    if workspace_dir and crate_dir:
        return _normalize_path(paths.normalize(paths.join(workspace_dir, crate_dir)))
    if workspace_dir:
        return _normalize_path(workspace_dir)
    return _normalize_path(crate_dir)

def _target_label(repo_name, package_path, target):
    if package_path:
        return "@%s//%s:%s" % (repo_name, package_path, target)
    return "@%s//:%s" % (repo_name, target)

def _additive_build_file_content(mctx, annotation):
    content = ""
    if annotation.additive_build_file:
        content += mctx.read(annotation.additive_build_file)
    content += annotation.additive_build_file_content
    return content

def _spec_to_dep_dict_inner(dep, spec, is_build = False):
    if type(spec) == "string":
        dep = {"name": dep}
    else:
        dep = {
            "name": dep,
            "optional": spec.get("optional", False),
            "default_features": spec.get("default_features", spec.get("default-features", True)),
            "features": spec.get("features", []),
        }
        if "package" in spec:
            dep["package"] = spec["package"]

    if is_build:
        dep["kind"] = "build"

    return dep

def _spec_to_dep_dict(dep, spec, annotation, workspace_cargo_toml_json, is_build = False):
    if type(spec) == "dict" and spec.get("workspace") == True:
        workspace = workspace_cargo_toml_json.get("workspace")
        if not workspace and annotation.workspace_cargo_toml != "Cargo.toml":
            fail("""

ERROR: `crate.annotation` for `{name}` has a `workspace_cargo_toml` pointing to a Cargo.toml without a `workspace` section. Please correct it in your MODULE.bazel!
Make sure you point to the `Cargo.toml` of the workspace, not of `{name}`!”

""".format(name = annotation.crate))

        inherited = _spec_to_dep_dict_inner(
            dep,
            workspace["dependencies"][dep],
            is_build,
        )

        extra_features = spec.get("features")
        if extra_features:
            inherited["features"] = sorted(set(extra_features + inherited.get("features", [])))

        if spec.get("optional"):
            inherited["optional"] = True

        if spec.get("package"):
            inherited["package"] = spec["package"]

        return inherited
    return _spec_to_dep_dict_inner(dep, spec, is_build)

def _generate_hub_and_spokes(
        mctx,
        hub_name,
        annotations,
        suggested_annotation_snippet_paths,
        cargo_path,
        cargo_lock_path,
        workspace_cargo_toml_json,
        all_packages,
        platform_triples,
        cargo_credentials,
        cargo_config,
        validate_lockfile,
        debug,
        use_legacy_rules_rust_platforms,
        dry_run = False):
    """Generates repositories for the transitive closure of the Cargo workspace.

    Args:
        mctx (module_ctx): The module context object.
        hub_name (string): name
        annotations (dict): Annotation tags to apply.
        suggested_annotation_snippet_paths (dict): Mapping crate -> snippet file path.
        cargo_path (path): Path to hermetic `cargo` binary.
        cargo_lock_path (path): Cargo.lock path
        workspace_cargo_toml_json (dict): Parsed workspace Cargo.toml
        all_packages: list[package]: from cargo lock parsing
        platform_triples (list[string]): Triples to resolve for
        cargo_credentials (dict): Mapping of registry to auth token.
        cargo_config (label): .cargo/config.toml file
        validate_lockfile (bool): If true, validate we have appropriate versions in Cargo.lock
        debug (bool): Enable debug logging
        dry_run (bool): Run all computations but do not create repos. Useful for benchmarking.
    """
    _date(mctx, "start")

    mctx.report_progress("Reading workspace metadata")
    result = mctx.execute(
        [cargo_path, "metadata", "--no-deps", "--format-version=1", "--quiet"],
        working_directory = str(mctx.path(cargo_lock_path).dirname),
    )
    if result.return_code != 0:
        fail(result.stdout + "\n" + result.stderr)
    cargo_metadata = json.decode(result.stdout)

    _date(mctx, "parsed cargo metadata")

    existing_facts = getattr(mctx, "facts", {}) or {}
    facts = {}

    workspace_root = _normalize_path(cargo_metadata["workspace_root"])
    workspace_root_prefix = workspace_root + "/"
    workspace_member_keys = {}
    for package in cargo_metadata["packages"]:
        workspace_member_keys[(package["name"], package["version"])] = True

    dep_paths_by_name = {}
    for package in cargo_metadata["packages"]:
        for dep in package.get("dependencies", []):
            dep_path = dep.get("path")
            if dep_path:
                dep_paths_by_name[dep["name"]] = _relative_to_workspace(dep_path, workspace_root)

    patch_paths_by_name = {}
    for registry_patches in workspace_cargo_toml_json.get("patch", {}).values():
        for name, spec in registry_patches.items():
            if type(spec) != "dict":
                continue

            patch_path = spec.get("path")
            if not patch_path:
                continue

            if patch_path.startswith("/"):
                normalized = _normalize_path(patch_path)
                if not normalized.startswith(workspace_root_prefix):
                    fail("Patch path for %s points outside the workspace: %s" % (name, patch_path))
                rel_patch_path = normalized.removeprefix(workspace_root_prefix)
            else:
                rel_patch_path = _normalize_path(paths.normalize(patch_path))

            patch_paths_by_name[name] = rel_patch_path

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
            local_path = paths.join(workspace_root, rel_path)

        if not local_path:
            fail("Found a path dependency on %s %s but could not determine its path from Cargo.toml. Please declare it in [patch] or as a path dependency." % (pkg["name"], pkg["version"]))

        pkg["source"] = "path+" + hub_name + "/" + rel_path
        pkg["local_path"] = local_path
        packages.append(pkg)

    mctx.report_progress("Computing dependencies and features")

    feature_resolutions_by_fq_crate = dict()

    versions_by_name = dict()
    for package_index in range(len(packages)):
        package = packages[package_index]
        name = package["name"]
        version = package["version"]
        source = package["source"]

        _add_to_dict(versions_by_name, name, version)

        if source.startswith("sparse+"):
            key = name + "_" + version
            fact = existing_facts.get(key)
            if fact:
                facts[key] = fact
                fact = json.decode(fact)
            else:
                package["download_token"].wait()

                # TODO(zbarsky): Should we also dedupe this parsing?
                metadatas = mctx.read(name + ".jsonl").strip().split("\n")
                version_needle = '"vers":"%s"' % version
                for metadata in metadatas:
                    if version_needle not in metadata:
                        continue
                    metadata = json.decode(metadata)
                    if metadata["vers"] != version:
                        continue

                    features = metadata["features"]

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
        elif source.startswith("path+"):
            # Always re-read path-dep Cargo.toml instead of using cached facts.
            # Path deps are local (fast to read), and their Cargo.toml can change
            # features/deps without changing the facts key, causing stale resolution.
            # Also watch the file so Bazel re-runs the extension when it changes.
            key = source + "_" + name
            cargo_toml_path = paths.join(package["local_path"], "Cargo.toml")
            mctx.watch(mctx.path(cargo_toml_path))
            annotation = annotation_for(annotations, name, package["version"])
            cargo_toml_json = run_toml2json(mctx, cargo_toml_path)

            dependencies = [
                _spec_to_dep_dict(dep, spec, annotation, {})
                for dep, spec in cargo_toml_json.get("dependencies", {}).items()
            ] + [
                _spec_to_dep_dict(dep, spec, annotation, {}, is_build = True)
                for dep, spec in cargo_toml_json.get("build-dependencies", {}).items()
            ]

            for target, value in cargo_toml_json.get("target", {}).items():
                for dep, spec in value.get("dependencies", {}).items():
                    converted = _spec_to_dep_dict(dep, spec, annotation, {})
                    converted["target"] = target
                    dependencies.append(converted)

            fact = dict(
                features = cargo_toml_json.get("features", {}),
                dependencies = dependencies,
                strip_prefix = "",
            )

            facts[key] = json.encode(fact)
            package["strip_prefix"] = fact.get("strip_prefix", "")
        elif source.startswith("git+"):
            key = source + "_" + name
            fact = existing_facts.get(key)
            if fact:
                facts[key] = fact
                fact = json.decode(fact)
            else:
                annotation = annotation_for(annotations, name, package["version"])
                info = package.get("member_crate_cargo_toml_info")
                if info:
                    # TODO(zbarsky): These tokens got enqueues last, so this can bottleneck
                    # We can try a bit harder to interleave things if we care.
                    info.token.wait()
                    package_workspace_cargo_toml_json = package["workspace_cargo_toml_json"]
                    cargo_toml_json = run_toml2json(mctx, info.path)
                else:
                    cargo_toml_json = package["cargo_toml_json"]
                    package_workspace_cargo_toml_json = package.get("workspace_cargo_toml_json")
                strip_prefix = package.get("strip_prefix", "")

                dependencies = [
                    _spec_to_dep_dict(dep, spec, annotation, package_workspace_cargo_toml_json)
                    for dep, spec in cargo_toml_json.get("dependencies", {}).items()
                ] + [
                    _spec_to_dep_dict(dep, spec, annotation, package_workspace_cargo_toml_json, is_build = True)
                    for dep, spec in cargo_toml_json.get("build-dependencies", {}).items()
                ]

                for target, value in cargo_toml_json.get("target", {}).items():
                    for dep, spec in value.get("dependencies", {}).items():
                        converted = _spec_to_dep_dict(dep, spec, annotation, package_workspace_cargo_toml_json)
                        converted["target"] = target
                        dependencies.append(converted)

                if not dependencies and debug:
                    print(name, version, package["source"])

                fact = dict(
                    features = cargo_toml_json.get("features", {}),
                    dependencies = dependencies,
                    strip_prefix = strip_prefix,
                )

                # Nest a serialized JSON since max path depth is 5.
                facts[key] = json.encode(fact)

            package["strip_prefix"] = fact["strip_prefix"]
        else:
            fail("Unknown source %s for crate %s" % (source, name))

        possible_features = fact["features"]
        possible_deps = _prepare_possible_deps(fact["dependencies"])
        feature_resolutions = _new_feature_resolutions(package_index, possible_deps, possible_features, platform_triples)
        package["feature_resolutions"] = feature_resolutions
        feature_resolutions_by_fq_crate[_fq_crate(name, version)] = feature_resolutions

    # Only files in the current Bazel workspace can/should be watched, so check where our manifests are located.
    watch_manifests = cargo_lock_path.repo_name == ""

    workspace_resolution = resolve_cargo_workspace_members(
        mctx,
        hub_name = hub_name,
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
        watch_manifests = watch_manifests,
        use_legacy_rules_rust_platforms = use_legacy_rules_rust_platforms,
    )
    cfg_match_cache = workspace_resolution.cfg_match_cache
    platform_cfg_attrs = workspace_resolution.platform_cfg_attrs
    workspace_dep_labels_by_triple = workspace_resolution.workspace_dep_labels_by_triple
    workspace_dep_versions_by_name = workspace_resolution.workspace_dep_versions_by_name

    _date(mctx, "set up initial deps!")

    mctx.report_progress("Initializing spokes")

    use_home_cargo_credentials = bool(cargo_credentials)

    for package in packages:
        crate_name = package["name"]
        version = package["version"]
        source = package["source"]

        feature_resolutions = feature_resolutions_by_fq_crate[_fq_crate(crate_name, version)]

        annotation = annotation_for(annotations, crate_name, version)
        suggested_annotation = None
        if annotation.gen_build_script == "auto":
            snippet_path = suggested_annotation_snippet_paths.get(crate_name)
            if snippet_path:
                suggested_annotation = mctx.read(snippet_path).strip()

        if suggested_annotation:
            print("""
WARNING: A well-known crate annotation exists for {crate}! Apply the following to your MODULE.bazel:

```
{formatted_well_known_annotation}
```

You can disable this warning by configuring your MODULE.bazel like so:

```
crate.annotation(
    crate = "{crate}",
    gen_build_script = "on",
)
```""".format(
                crate = crate_name,
                formatted_well_known_annotation = suggested_annotation,
            ))

        kwargs = dict(
            hub_name = hub_name,
            gen_build_script = annotation.gen_build_script,
            build_script_deps = [],
            build_script_deps_select = _select(feature_resolutions.build_deps),
            build_script_data = annotation.build_script_data,
            build_script_data_select = annotation.build_script_data_select,
            build_script_env = annotation.build_script_env,
            build_script_toolchains = annotation.build_script_toolchains,
            build_script_tools = annotation.build_script_tools,
            build_script_tags = annotation.build_script_tags,
            build_script_tools_select = annotation.build_script_tools_select,
            build_script_env_select = annotation.build_script_env_select,
            rustc_flags = annotation.rustc_flags,
            rustc_flags_select = annotation.rustc_flags_select,
            data = annotation.data,
            deps = annotation.deps,
            crate_tags = annotation.tags,
            deps_select = _select(feature_resolutions.deps),
            aliases = feature_resolutions.aliases,
            crate_features = annotation.crate_features,
            crate_features_select = _select(feature_resolutions.features_enabled),
            use_legacy_rules_rust_platforms = use_legacy_rules_rust_platforms,
        )

        repo_name = _spoke_repo(hub_name, crate_name, version)
        package["target_repo_name"] = repo_name
        package["target_package_path"] = ""

        if source.startswith("sparse+"):
            checksum = package["checksum"]

            if dry_run:
                continue

            qualifiers = {}
            if source != CRATES_IO_REGISTRY:
                qualifiers["repository_url"] = source.split("+", 1)[1]

            crate_repository(
                name = repo_name,
                additive_build_file = annotation.additive_build_file,
                additive_build_file_content = annotation.additive_build_file_content,
                crate_name = crate_name,
                version = version,
                registry_config = "@%s//:dl" % registry_config_repo_name(hub_name, source),
                sbom_extra_qualifiers = qualifiers,
                checksum = checksum,
                gen_binaries = annotation.gen_binaries,
                patch_args = annotation.patch_args,
                patch_tool = annotation.patch_tool,
                patches = annotation.patches,
                # The repository will need to recompute these, but this lets us avoid serializing them.
                use_home_cargo_credentials = use_home_cargo_credentials,
                cargo_config = cargo_config,
                source = source,
                **kwargs
            )
        elif source.startswith("path+"):
            if dry_run:
                continue

            # TODO What PURL should that be ?
            local_crate_repository(
                name = repo_name,
                additive_build_file = annotation.additive_build_file,
                additive_build_file_content = annotation.additive_build_file_content,
                gen_binaries = annotation.gen_binaries,
                patch_args = annotation.patch_args,
                patch_tool = annotation.patch_tool,
                patches = annotation.patches,
                path = package["local_path"],
                **kwargs
            )
        elif source.startswith("git+"):
            remote, commit = parse_git_url(source)

            package_path = _git_crate_package_path(annotation, package.get("strip_prefix"))
            package["target_repo_name"] = _external_repo_for_git_source(hub_name, remote, commit)
            package["target_package_path"] = package_path

            if dry_run:
                continue

            git_crate_metadata_repository(
                name = repo_name,
                package_name = crate_name,
                package_version = version,
                purl = _git_crate_purl(crate_name, version, remote, commit),
                **kwargs
            )
        else:
            fail("Unknown source %s for crate %s" % (source, crate_name))

    _date(mctx, "created repos")

    mctx.report_progress("Initializing hub")

    package_by_fq = {
        _fq_crate(package["name"], package["version"]): package
        for package in packages
    }

    hub_contents = []
    for name, versions in versions_by_name.items():
        for version in versions:
            annotation = annotation_for(annotations, name, version)
            package = package_by_fq[_fq_crate(name, version)]
            target_repo_name = package["target_repo_name"]
            target_package_path = package["target_package_path"]

            hub_contents.append("""
alias(
    name = "{name}-{version}",
    actual = "{actual}",
)""".format(name = name, version = version, actual = _target_label(target_repo_name, target_package_path, name)))

            for binary in annotation.gen_binaries:
                hub_contents.append("""
alias(
    name = "{name}-{version}__{binary}",
    actual = "{actual}",
)""".format(name = name, version = version, binary = binary, actual = _target_label(target_repo_name, target_package_path, binary + "__bin")))

            for alias_name, target in sorted(annotation.extra_aliased_targets.items()):
                hub_contents.append("""
alias(
    name = "{alias_name}-{version}",
    actual = "{actual}",
)""".format(
                    alias_name = alias_name,
                    version = version,
                    actual = _target_label(target_repo_name, target_package_path, target),
                ))

        workspace_versions = workspace_dep_versions_by_name.get(name)
        if workspace_versions:
            fq = sorted(workspace_versions)[-1]
            default_version = fq[len(name) + 1:]
            annotation = annotation_for(annotations, name, default_version)

            hub_contents.append("""
alias(
    name = "{name}",
    actual = ":{fq}",
)""".format(name = name, fq = fq))

            for binary in annotation.gen_binaries:
                hub_contents.append("""
alias(
    name = "{name}__{binary}",
    actual = ":{fq}__{binary}",
)""".format(name = name, fq = fq, binary = binary))

            for alias_name in sorted(annotation.extra_aliased_targets.keys()):
                hub_contents.append("""
alias(
    name = "{alias_name}",
    actual = ":{alias_name}-{default_version}",
)""".format(
                    alias_name = alias_name,
                    default_version = default_version,
                ))

    workspace_deps, conditional_workspace_deps = render_select(
        [],
        workspace_dep_labels_by_triple,
        use_legacy_rules_rust_platforms,
    )

    hub_contents.append(
        """
package(
    default_visibility = ["//visibility:public"],
)

filegroup(
    name = "_workspace_deps",
    srcs = [
        %s
    ]%s,
)""" % (
            ",\n        ".join(['"%s"' % dep for dep in sorted(workspace_deps)]),
            " + " + conditional_workspace_deps if conditional_workspace_deps else "",
        ),
    )

    lint_flags = cargo_toml_lint_flags(workspace_cargo_toml_json)
    hub_contents.append(
        """
load("@rules_rs//rs/private:cargo_lints.bzl", "cargo_lints")

cargo_lints(
    name = "cargo_lints",
    rustc_lint_flags = [
        {rustc}
    ],
    clippy_lint_flags = [
        {clippy}
    ],
    rustdoc_lint_flags = [
        {rustdoc}
    ],
)""".format(
            rustc = _render_ordered_string_list(lint_flags.rustc_lint_flags),
            clippy = _render_ordered_string_list(lint_flags.clippy_lint_flags),
            rustdoc = _render_ordered_string_list(lint_flags.rustdoc_lint_flags),
        ),
    )

    resolved_platforms = []
    for triple in platform_triples:
        platform = platform_label(triple, use_legacy_rules_rust_platforms)
        if platform not in resolved_platforms:
            resolved_platforms.append(platform)

    defs_bzl_contents = \
        """load(":data.bzl", "DEP_DATA")
load("@rules_rs//rs/private:all_crate_deps.bzl", _all_crate_deps = "all_crate_deps")

_PLATFORMS = [
    {platforms}
]

def aliases(package_name = None):
    dep_data = DEP_DATA.get(package_name or native.package_name())
    if not dep_data:
        return {{}}

    return dep_data["aliases"]

def all_crate_deps(
        normal = False,
        normal_dev = False,
        build = False,
        package_name = None,
        cargo_only = False):

    dep_data = DEP_DATA.get(package_name or native.package_name())
    if not dep_data:
        return []

    return _all_crate_deps(
        dep_data,
        platforms = _PLATFORMS,
        normal = normal,
        normal_dev = normal_dev,
        build = build,
        filter_prefix = {this_repo} if cargo_only else None,
    )

RESOLVED_PLATFORMS = select({{
    {target_compatible_with},
    "//conditions:default": ["@platforms//:incompatible"],
}})
""".format(
            platforms = render_string_list(resolved_platforms),
            target_compatible_with = ",\n    ".join(['"%s": []' % platform for platform in resolved_platforms]),
            this_repo = repr("@" + hub_name + "//:"),
        )

    _date(mctx, "done")

    repo_root = _normalize_path(cargo_metadata["workspace_root"])
    workspace_package = _label_directory(cargo_lock_path)
    data_bzl_contents = render_dep_data(workspace_dep_data(
        cargo_metadata = cargo_metadata,
        feature_resolutions_by_fq_crate = feature_resolutions_by_fq_crate,
        platform_triples = platform_triples,
        platform_cfg_attrs = platform_cfg_attrs,
        cfg_match_cache = cfg_match_cache,
        repo_root = repo_root,
        workspace_package = workspace_package,
        use_legacy_rules_rust_platforms = use_legacy_rules_rust_platforms,
    ))

    if dry_run:
        return

    _hub_repo(
        name = hub_name,
        contents = {
            "BUILD.bazel": "\n".join(hub_contents),
            "defs.bzl": defs_bzl_contents,
            "data.bzl": data_bzl_contents,
        },
    )

    return facts

def _crate_impl(mctx):
    # TODO(zbarsky): Kick off `cargo` fetch early to mitigate https://github.com/bazelbuild/bazel/issues/26995
    cargo_path = mctx.path(RS_HOST_CARGO_LABEL)

    # And toml2json
    toml2json = mctx.path(Label("@toml2json_%s//file:downloaded" % repo_utils.platform(mctx)))

    downloader_state = new_downloader_state()
    suggested_annotation_snippet_paths = well_known_annotation_snippet_paths(mctx)

    packages_by_hub_name = {}
    cargo_toml_by_hub_name = {}
    cargo_credentials_by_hub_name = {}
    annotations_by_hub_name = {}

    for mod in mctx.modules:
        if not mod.tags.from_cargo:
            fail("`.from_cargo` is required. Please update %s" % mod.name)

        for cfg in mod.tags.from_cargo:
            annotations = build_annotation_map(mod, cfg.name)
            annotations_by_hub_name[cfg.name] = annotations
            mctx.watch(cfg.cargo_lock)
            mctx.watch(cfg.cargo_toml)
            cargo_toml_by_hub_name[cfg.name] = run_toml2json(mctx, cfg.cargo_toml)
            cargo_lock = run_toml2json(mctx, cfg.cargo_lock)
            parsed_packages = cargo_lock.get("package", [])
            for package in parsed_packages:
                package["hub_name"] = cfg.name
            packages_by_hub_name[cfg.name] = parsed_packages

            # Process git downloads first because they may require a followup download if the repo is a workspace,
            # so we want to enqueue them early so they don't get delayed by 1-shot registry downloads.
            start_github_downloads(mctx, downloader_state, annotations, parsed_packages)

    for mod in mctx.modules:
        for cfg in mod.tags.from_cargo:
            annotations = build_annotation_map(mod, cfg.name)

            if cfg.use_home_cargo_credentials:
                if not cfg.cargo_config:
                    fail("Must provide cargo_config when using cargo credentials")

                cargo_credentials = load_cargo_credentials(mctx, cfg.cargo_config)
            else:
                cargo_credentials = {}

            cargo_credentials_by_hub_name[cfg.name] = cargo_credentials
            packages = packages_by_hub_name[cfg.name]
            registry_sources = set()

            for package in packages:
                source = package.get("source")
                if source == "registry+https://github.com/rust-lang/crates.io-index":
                    source = CRATES_IO_REGISTRY
                    package["source"] = source

                if source and source.startswith("sparse+"):
                    registry_sources.add(source)

            start_crate_registry_downloads(mctx, downloader_state, annotations, packages, cargo_credentials, cfg.debug)

            for source in sorted(registry_sources):
                registry_config_repository(
                    name = registry_config_repo_name(cfg.name, source),
                    source = source,
                    cargo_config = cfg.cargo_config,
                    use_home_cargo_credentials = cfg.use_home_cargo_credentials,
                )

    for fetch_state in downloader_state.in_flight_git_crate_fetches_by_url.values():
        fetch_state.download_token.wait()

    download_metadata_for_git_crates(mctx, downloader_state, annotations_by_hub_name)

    facts = {}
    direct_deps = []
    direct_dev_deps = []

    for mod in mctx.modules:
        for cfg in mod.tags.from_cargo:
            if mod.is_root:
                if mctx.is_dev_dependency(cfg):
                    direct_dev_deps.append(cfg.name)
                else:
                    direct_deps.append(cfg.name)

            hub_packages = packages_by_hub_name[cfg.name]
            cargo_credentials = cargo_credentials_by_hub_name[cfg.name]

            annotations = build_annotation_map(mod, cfg.name)

            if cfg.debug:
                for _ in range(25):
                    _generate_hub_and_spokes(mctx, cfg.name, annotations, suggested_annotation_snippet_paths, cargo_path, cfg.cargo_lock, cargo_toml_by_hub_name[cfg.name], hub_packages, cfg.platform_triples, cargo_credentials, cfg.cargo_config, cfg.validate_lockfile, cfg.debug, cfg.use_legacy_rules_rust_platforms, dry_run = True)

            facts |= _generate_hub_and_spokes(mctx, cfg.name, annotations, suggested_annotation_snippet_paths, cargo_path, cfg.cargo_lock, cargo_toml_by_hub_name[cfg.name], hub_packages, cfg.platform_triples, cargo_credentials, cfg.cargo_config, cfg.validate_lockfile, cfg.debug, cfg.use_legacy_rules_rust_platforms)

    # Lay down the git repos with generated per-crate BUILD overlays.
    git_repos = {}
    for mod in mctx.modules:
        for cfg in mod.tags.from_cargo:
            annotations = build_annotation_map(mod, cfg.name)
            for package in packages_by_hub_name[cfg.name]:
                source = package.get("source", "")
                if not source.startswith("git+"):
                    continue

                remote, commit = parse_git_url(source)
                annotation = annotation_for(annotations, package["name"], package["version"])
                repo_name = _external_repo_for_git_source(cfg.name, remote, commit)
                git_repo = git_repos.get(repo_name)
                if not git_repo:
                    git_repo = {
                        "build_files": {},
                        "gen_binaries": {},
                        "commit": commit,
                        "hub_name": cfg.name,
                        "patch_args": [],
                        "patch_tool": "",
                        "patches": {},
                        "remote": remote,
                        "workspace_cargo_toml": annotation.workspace_cargo_toml,
                    }
                    git_repos[repo_name] = git_repo

                strip_prefix = package.get("strip_prefix")
                if strip_prefix == None:
                    strip_prefix = json.decode(facts[source + "_" + package["name"]])["strip_prefix"]
                package_path = _git_crate_package_path(annotation, strip_prefix)
                build_file_path = paths.join(package_path, "BUILD.bazel") if package_path else "BUILD.bazel"
                git_repo["build_files"][build_file_path] = _additive_build_file_content(mctx, annotation)
                if annotation.gen_binaries:
                    git_repo["gen_binaries"][build_file_path] = annotation.gen_binaries

                if annotation.patches:
                    patch_args = annotation.patch_args
                    patch_tool = annotation.patch_tool or ""
                    if git_repo["patches"] and (git_repo["patch_args"] != patch_args or git_repo["patch_tool"] != patch_tool):
                        fail("Git crates from %s use incompatible patch settings" % source)

                    git_repo["patch_args"] = patch_args
                    git_repo["patch_tool"] = patch_tool
                    for patch_file in annotation.patches:
                        git_repo["patches"][str(patch_file)] = patch_file

    for repo_name, git_repo in git_repos.items():
        kwargs = {}
        if git_repo["gen_binaries"]:
            kwargs["gen_binaries"] = git_repo["gen_binaries"]

        git_cargo_workspace_repository(
            name = repo_name,
            build_files = git_repo["build_files"],
            commit = git_repo["commit"],
            hub_name = git_repo["hub_name"],
            patch_args = git_repo["patch_args"],
            patch_tool = git_repo["patch_tool"],
            patches = git_repo["patches"].values(),
            remote = git_repo["remote"],
            workspace_cargo_toml = git_repo["workspace_cargo_toml"],
            **kwargs
        )

    kwargs = dict(
        root_module_direct_deps = direct_deps,
        root_module_direct_dev_deps = direct_dev_deps,
        reproducible = True,
    )

    if hasattr(mctx, "facts"):
        kwargs["facts"] = facts

    return mctx.extension_metadata(**kwargs)

_from_cargo = tag_class(
    doc = "Generates a repo @crates from a Cargo.toml / Cargo.lock pair.",
    # Ordering is controlled for readability in generated docs.
    attrs = {
        "name": attr.string(
            doc = "The name of the repo to generate",
            default = "crates",
        ),
    } | {
        "cargo_toml": attr.label(
            doc = "The workspace-level Cargo.toml. There can be multiple crates in the workspace.",
        ),
        "cargo_lock": attr.label(),
        "cargo_config": attr.label(),
        "use_home_cargo_credentials": attr.bool(
            doc = "If set, the ruleset will load `~/cargo/credentials.toml` and attach those credentials to registry requests.",
        ),
        "platform_triples": attr.string_list(
            mandatory = True,
            doc = "The set of triples to resolve for. They must correspond to the union of any exec/target platforms that will participate in your build.",
        ),
        "use_legacy_rules_rust_platforms": attr.bool(
            doc = "If true, use the legacy rules_rust platforms. If false, use rules_rs platforms.",
            default = False,
        ),
        "validate_lockfile": attr.bool(
            doc = "If true, fail if Cargo.lock versions don't satisfy Cargo.toml requirements.",
            default = True,
        ),
        "debug": attr.bool(),
    },
)

_relative_label_list = attr.string_list

_annotation = tag_class(
    doc = "A collection of extra attributes and settings for a particular crate.",
    attrs = {
        "crate": attr.string(
            doc = "The name of the crate the annotation is applied to",
            mandatory = True,
        ),
        "version": attr.string(
            doc = "The version of the crate the annotation is applied to. Defaults to all versions.",
            default = "*",
        ),
        "repositories": attr.string_list(
            doc = "A list of repository names specified from `crate.from_cargo(name=...)` that this annotation is applied to. Defaults to all repositories.",
            default = [],
        ),
    } | {
        "additive_build_file": attr.label(
            doc = "A file containing extra contents to write to the bottom of generated BUILD files.",
        ),
        "additive_build_file_content": attr.string(
            doc = "Extra contents to write to the bottom of generated BUILD files.",
        ),
        # "alias_rule": attr.string(
        #     doc = "Alias rule to use instead of `native.alias()`.  Overrides [render_config](#render_config)'s 'default_alias_rule'.",
        # ),
        "build_script_data": _relative_label_list(
            doc = "A list of labels to add to a crate's `cargo_build_script::data` attribute.",
        ),
        # "build_script_data_glob": attr.string_list(
        #     doc = "A list of glob patterns to add to a crate's `cargo_build_script::data` attribute",
        # ),
        "build_script_data_select": attr.string_list_dict(
            doc = "A list of labels to add to a crate's `cargo_build_script::data` attribute. Keys should be the platform triplet. Value should be a list of labels.",
        ),
        # "build_script_deps": _relative_label_list(
        #     doc = "A list of labels to add to a crate's `cargo_build_script::deps` attribute.",
        # ),
        "build_script_env": attr.string_dict(
            doc = "Additional environment variables to set on a crate's `cargo_build_script::env` attribute.",
        ),
        "build_script_env_select": attr.string_dict(
            doc = "Additional environment variables to set on a crate's `cargo_build_script::env` attribute. Key should be the platform triplet. Value should be a JSON encoded dictionary mapping variable names to values, for example `{\"FOO\": \"bar\"}`.",
        ),
        # "build_script_link_deps": _relative_label_list(
        #     doc = "A list of labels to add to a crate's `cargo_build_script::link_deps` attribute.",
        # ),
        # "build_script_rundir": attr.string(
        #     doc = "An override for the build script's rundir attribute.",
        # ),
        # "build_script_rustc_env": attr.string_dict(
        #     doc = "Additional environment variables to set on a crate's `cargo_build_script::env` attribute.",
        # ),
        "build_script_toolchains": attr.label_list(
            doc = "A list of labels to set on a crates's `cargo_build_script::toolchains` attribute.",
        ),
        "build_script_tags": attr.string_list(
            doc = "A list of tags to add to a crate's `cargo_build_script` target.",
        ),
        "build_script_tools": _relative_label_list(
            doc = "A list of labels to add to a crate's `cargo_build_script::tools` attribute.",
        ),
        "build_script_tools_select": attr.string_list_dict(
            doc = "A list of labels to add to a crate's `cargo_build_script::tools` attribute. Keys should be the platform triplet. Value should be a list of labels.",
        ),
        # "compile_data": _relative_label_list(
        # doc = "A list of labels to add to a crate's `rust_library::compile_data` attribute.",
        # ),
        # "compile_data_glob": attr.string_list(
        # doc = "A list of glob patterns to add to a crate's `rust_library::compile_data` attribute.",
        # ),
        # "compile_data_glob_excludes": attr.string_list(
        # doc = "A list of glob patterns to be excllued from a crate's `rust_library::compile_data` attribute.",
        # ),
        "crate_features": attr.string_list(
            doc = "A list of strings to add to a crate's `rust_library::crate_features` attribute.",
        ),
        "crate_features_select": attr.string_list_dict(
            doc = "A list of strings to add to a crate's `rust_library::crate_features` attribute. Keys should be the platform triplet. Value should be a list of features.",
        ),
        "data": _relative_label_list(
            doc = "A list of labels to add to a crate's `rust_library::data` attribute.",
        ),
        # "data_glob": attr.string_list(
        #     doc = "A list of glob patterns to add to a crate's `rust_library::data` attribute.",
        # ),
        "deps": _relative_label_list(
            doc = "A list of labels to add to a crate's `rust_library::deps` attribute.",
        ),
        "tags": attr.string_list(
            doc = "A list of tags to add to a crate's generated targets.",
        ),
        # "disable_pipelining": attr.bool(
        #     doc = "If True, disables pipelining for library targets for this crate.",
        # ),
        "extra_aliased_targets": attr.string_dict(
            doc = "A list of targets to add to the generated aliases in the root crate repository.",
        ),
        # "gen_all_binaries": attr.bool(
        #     doc = "If true, generates `rust_binary` targets for all of the crates bins",
        # ),
        "gen_binaries": attr.string_list(
            doc = "As a list, the subset of the crate's bins that should get `rust_binary` targets produced.",
        ),
        "gen_build_script": attr.string(
            doc = "An authoritative flag to determine whether or not to produce `cargo_build_script` targets for the current crate. Supported values are 'on', 'off', and 'auto'.",
            values = ["auto", "on", "off"],
            default = "auto",
        ),
        # "override_target_bin": attr.label(
        #     doc = "An optional alternate target to use when something depends on this crate to allow the parent repo to provide its own version of this dependency.",
        # ),
        # "override_target_build_script": attr.label(
        #     doc = "An optional alternate target to use when something depends on this crate to allow the parent repo to provide its own version of this dependency.",
        # ),
        # "override_target_lib": attr.label(
        #     doc = "An optional alternate target to use when something depends on this crate to allow the parent repo to provide its own version of this dependency.",
        # ),
        # "override_target_proc_macro": attr.label(
        #     doc = "An optional alternate target to use when something depends on this crate to allow the parent repo to provide its own version of this dependency.",
        # ),
        "patch_args": attr.string_list(
            doc = "The `patch_args` attribute of a Bazel repository rule. See [http_archive.patch_args](https://docs.bazel.build/versions/main/repo/http.html#http_archive-patch_args)",
        ),
        "patch_tool": attr.string(
            doc = "The `patch_tool` attribute of a Bazel repository rule. See [http_archive.patch_tool](https://docs.bazel.build/versions/main/repo/http.html#http_archive-patch_tool)",
        ),
        "patches": attr.label_list(
            doc = "The `patches` attribute of a Bazel repository rule. See [http_archive.patches](https://docs.bazel.build/versions/main/repo/http.html#http_archive-patches)",
        ),
        # "rustc_env": attr.string_dict(
        #     doc = "Additional variables to set on a crate's `rust_library::rustc_env` attribute.",
        # ),
        # "rustc_env_files": _relative_label_list(
        #     doc = "A list of labels to set on a crate's `rust_library::rustc_env_files` attribute.",
        # ),
        "rustc_flags": attr.string_list(
            doc = "A list of strings to set on a crate's `rust_library::rustc_flags` attribute.",
        ),
        "rustc_flags_select": attr.string_list_dict(
            doc = "A list of strings to set on a crate's `rust_library::rustc_flags` attribute. Keys should be the platform triplet. Value should be a list of flags.",
        ),
        # "shallow_since": attr.string(
        #     doc = "An optional timestamp used for crates originating from a git repository instead of a crate registry. This flag optimizes fetching the source code.",
        # ),
        "strip_prefix": attr.string(),
        "workspace_cargo_toml": attr.string(
            doc = "For crates from git, the ruleset assumes the (workspace) Cargo.toml is in the repo root. This attribute overrides the assumption.",
            default = "Cargo.toml",
        ),
    },
)

crate = module_extension(
    implementation = _crate_impl,
    tag_classes = {
        "annotation": _annotation,
        "from_cargo": _from_cargo,
    },
)

def _hub_repo_impl(rctx):
    for path, contents in rctx.attr.contents.items():
        rctx.file(path, contents)
    rctx.file("REPO.bazel", "")

_hub_repo = repository_rule(
    implementation = _hub_repo_impl,
    attrs = {
        "contents": attr.string_dict(
            doc = "A mapping of file names to text they should contain.",
            mandatory = True,
        ),
    },
)
