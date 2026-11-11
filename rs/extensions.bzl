load("@bazel_skylib//lib:paths.bzl", "paths")
load("@host_cargo//:defs.bzl", "RS_HOST_CARGO_LABEL")
load("//rs/private:annotations.bzl", "annotation_for", "build_annotation_map", "well_known_annotation_snippet_paths")
load("//rs/private:cargo_credentials.bzl", "load_cargo_credentials")
load(
    "//rs/private:cargo_workspace_graph.bzl",
    "cargo_platforms",
    "cargo_toml_fact",
    "platform_label",
    "render_dep_data",
    "render_string_list",
    "resolve_cargo_workspace_members",
    "resolve_package_facts",
    "split_lockfile_packages",
    "workspace_dep_data",
    _fq_crate = "fq_crate",
    _manifest_package_dir = "manifest_package_dir",
    _normalize_path = "normalize_path",
)
load("//rs/private:crate_repository.bzl", "crate_repository", "local_crate_repository")
load("//rs/private:downloader.bzl", "download_metadata_for_git_crates", "new_downloader_state", "parse_git_url", "start_crate_downloads", "start_github_download", _read_member_manifest = "read_member_manifest")
load("//rs/private:git_cargo_workspace_repository.bzl", "git_cargo_workspace_repository")
load("//rs/private:git_crate_metadata_repository.bzl", "git_crate_metadata_repository")
load("//rs/private:lint_flags.bzl", "cargo_toml_lint_flags", "workspace_cargo_toml_lint_flags")
load("//rs/private:registry_config_repository.bzl", "registry_config_repository")
load("//rs/private:registry_utils.bzl", "CRATES_IO_REGISTRY", "registry_config_repo_name", "resolve_registry_source")
load("//rs/private:repository_utils.bzl", "render_select", "spoke_repo_name")
load("//rs/private:toml2json.bzl", "run_toml2json")
load("//rs/private:visibility.bzl", "visibility_with_internal_access")

def _git_repo_remote_name(remote):
    scheme_separator = remote.find("://")
    if scheme_separator != -1:
        remote = remote[scheme_separator + len("://"):]

    return remote.replace("/", "_").replace(":", "_").replace("@", "_")

def _external_repo_for_git_source(hub_name, remote, commit):
    return hub_name + "__" + _git_repo_remote_name(remote) + "_" + commit[:8]

def _git_crate_purl(name, version, remote, commit):
    return "pkg:cargo/%s@%s?vcs_url=git+%s@%s" % (name, version, remote, commit)

def _render_ordered_string_list(items):
    """Renders lint flags in the order Cargo applies them."""
    return ",\n        ".join([repr(item) for item in items])

def _render_alias(name, actual, visibility):
    return """
alias(
    name = %r,
    actual = %r,
    visibility = %r,
)""" % (name, actual, visibility)

def _render_cargo_lints_target(name, lint_flags):
    return """
cargo_lints(
    name = {name},
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
        name = repr(name),
        rustc = _render_ordered_string_list(lint_flags.rustc_lint_flags),
        clippy = _render_ordered_string_list(lint_flags.clippy_lint_flags),
        rustdoc = _render_ordered_string_list(lint_flags.rustdoc_lint_flags),
    )

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
    return _normalize_path(workspace_dir or crate_dir)

def _target_label(repo_name, package_path, target):
    return "@%s//%s:%s" % (repo_name, package_path, target)

def _add_git_crate(git_repos, hub, package, remote, commit):
    repo_name = package["target_repo_name"]
    annotation = package["annotation"]
    git_repo = git_repos.get(repo_name)
    if not git_repo:
        archive_url = ""
        if remote.startswith("https://github.com/"):
            repo_path = remote.removeprefix("https://github.com/").removesuffix(".git")
            archive_url = "https://codeload.github.com/%s/tar.gz/%s" % (repo_path, commit)

        git_repo = {
            "allow_git_cli": hub.allow_git_cli,
            "archive_url": archive_url,
            "build_annotations": {},
            "commit": commit,
            "hub_name": hub.cfg.name,
            "patch_args": [],
            "patch_tool": "",
            "patches": set(),
            "remote": remote,
            "use_git": False,
            "workspace_cargo_toml": annotation.workspace_cargo_toml,
        }
        git_repos[repo_name] = git_repo
    elif git_repo["remote"] != remote or git_repo["commit"] != commit:
        fail("Git crates from %s at %s and %s at %s produce the same repository name %s" % (
            git_repo["remote"],
            git_repo["commit"],
            remote,
            commit,
            repo_name,
        ))

    # Git crates from the same commit share one checkout per hub.
    if annotation.use_git:
        git_repo["use_git"] = True

    build_file_path = paths.join(package["target_package_path"], "BUILD.bazel")
    git_repo["build_annotations"][build_file_path] = annotation
    if annotation.gen_binaries:
        git_repo.setdefault("gen_binaries", {})[build_file_path] = annotation.gen_binaries

    if annotation.patches:
        patch_args = annotation.patch_args
        patch_tool = annotation.patch_tool or ""
        if git_repo["patches"] and (git_repo["patch_args"] != patch_args or git_repo["patch_tool"] != patch_tool):
            fail("Git crates from %s use incompatible patch settings" % repo_name)

        git_repo["patch_args"] = patch_args
        git_repo["patch_tool"] = patch_tool
        git_repo["patches"].update(annotation.patches)

def _registry_crate_fact(mctx, package):
    name = package["name"]
    version = package["version"]
    package["download_token"].wait()

    for line in mctx.read(name + ".jsonl").strip().split("\n"):
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

        return dict(features = features, dependencies = dependencies)
    fail("Sparse registry %s has no metadata for %s %s" % (package["source"], name, version))

def _git_crate_fact(mctx, package, debug):
    member = package.get("member_crate_cargo_toml_info")
    if member:
        cargo_toml = _read_member_manifest(mctx, member)
    else:
        cargo_toml = package["cargo_toml_json"]
    fact = cargo_toml_fact(cargo_toml, package.get("workspace_cargo_toml_json"), strip_prefix = package.get("strip_prefix", ""))
    if debug and not fact["dependencies"]:
        print(package["name"], package["version"], package["source"])
    return fact

def _generate_hub_and_spokes(mctx, hub, platforms, cargo_path, suggested_annotation_snippet_paths, git_repos, facts):
    cfg = hub.cfg
    hub_name = cfg.name
    platform_triples = platforms.bits.keys()
    use_legacy_rules_rust_platforms = cfg.use_legacy_rules_rust_platforms
    mctx.report_progress("Reading workspace metadata")

    # Keep metadata paths under external/<repo> so mctx.watch can track files
    # even when the repository is symlinked into the repository contents cache.
    manifest = mctx.path(cfg.cargo_toml)
    result = mctx.execute(
        [cargo_path, "metadata", "--manifest-path", manifest, "--no-deps", "--locked", "--format-version=1", "--quiet"] +
        (["--config", str(mctx.path(hub.cargo_config))] if hub.cargo_config else []),
        working_directory = str(manifest.dirname),
    )
    if result.return_code != 0:
        fail(result.stdout + "\n" + result.stderr)
    cargo_metadata = json.decode(result.stdout)
    for member in cargo_metadata["packages"]:
        mctx.watch(member["manifest_path"])

    existing_facts = getattr(mctx, "facts", {}) or {}

    workspace_cargo_toml_json = run_toml2json(mctx, cfg.cargo_toml)
    split_packages = split_lockfile_packages(
        hub_name,
        cargo_metadata,
        workspace_cargo_toml_json,
        hub.packages,
    )
    packages = split_packages.packages
    workspace_members = split_packages.workspace_members

    mctx.report_progress("Computing dependencies and features")

    # All spokes need visibility to the crates they depend on, including Git checkouts.
    internal_packages = set(["@%s//:__pkg__" % hub_name])
    facts_by_fq_crate = {}
    package_by_fq = {}
    for package in packages:
        name = package["name"]
        version = package["version"]
        git_source = package.get("git_source")
        if package["source"].startswith("path+"):
            # Local Cargo.toml can change without a Cargo.lock edit.
            manifest_path = paths.join(package["local_path"], "Cargo.toml")
            mctx.watch(manifest_path)
            fact = cargo_toml_fact(run_toml2json(mctx, manifest_path))
        else:
            key = package["fact_key"]
            encoded_fact = existing_facts.get(key)
            if encoded_fact != None:
                facts[key] = encoded_fact
                fact = json.decode(encoded_fact)
            else:
                fact = _git_crate_fact(mctx, package, cfg.debug) if git_source else _registry_crate_fact(mctx, package)

                # Encode the manifest because Bazel limits the depth of extension facts.
                facts[key] = json.encode(fact)

        if git_source:
            package["strip_prefix"] = fact["strip_prefix"]
            remote, commit = git_source
            repo_name = _external_repo_for_git_source(hub_name, remote, commit)
        else:
            repo_name = spoke_repo_name(hub_name, name, version)
        package["target_repo_name"] = repo_name
        internal_packages.add("@%s//:__subpackages__" % repo_name)
        fq = _fq_crate(name, version)
        facts_by_fq_crate[fq] = fact
        package_by_fq[fq] = package

    resolved_facts = resolve_package_facts(packages, facts_by_fq_crate)

    workspace_resolution = resolve_cargo_workspace_members(
        mctx,
        cargo_metadata = cargo_metadata,
        packages = packages,
        workspace_members = workspace_members,
        package_resolution = resolved_facts,
        annotations = hub.annotations,
        platforms = platforms,
        materialize_workspace_members = False,
        validate_lockfile = cfg.validate_lockfile,
        debug = cfg.debug,
        dep_label_prefix = "@%s//:" % hub_name,
    )

    mctx.report_progress("Initializing spokes")

    internal_packages = list(internal_packages)

    for package in packages:
        crate_name = package["name"]
        version = package["version"]
        source = package["source"]

        feature_resolutions = resolved_facts.feature_resolutions_by_fq_crate[_fq_crate(crate_name, version)]

        annotation = package["annotation"]
        package["visibility"] = visibility_with_internal_access(annotation.visibility, internal_packages)
        suggested_annotation = None
        if annotation.gen_build_script == "auto":
            snippet_path = suggested_annotation_snippet_paths.get(crate_name)
            if snippet_path:
                suggested_annotation = mctx.read(snippet_path).strip()
        deps_select = dict(feature_resolutions.deps) if annotation.deps_select else feature_resolutions.deps
        for triple, deps in annotation.deps_select.items():
            deps_select[triple] = deps_select.get(triple, []) + deps

        if suggested_annotation:
            print("""
WARNING: A well-known crate annotation exists to make builds of {crate} in Cargo hub {hub_name} more hermetic! Apply the following to your MODULE.bazel:

```
{formatted_well_known_annotation}
```

If non-hermetic builds of {crate} are acceptable, then you can disable this warning by configuring your MODULE.bazel like so:

```
crate.annotation(
    crate = "{crate}",
    gen_build_script = "on",
)
```""".format(
                crate = crate_name,
                formatted_well_known_annotation = suggested_annotation,
                hub_name = hub_name,
            ))

        kwargs = dict(
            hub_name = hub_name,
            crate_visibility = package["visibility"],
            gen_build_script = annotation.gen_build_script,
            build_script_deps = [],
            build_script_deps_select = feature_resolutions.build_deps,
            build_script_data = annotation.build_script_data,
            build_script_data_select = annotation.build_script_data_select,
            build_script_env = annotation.build_script_env,
            build_script_env_files = annotation.build_script_env_files,
            allow_build_script_to_detect_nonhermetic_paths = annotation.allow_build_script_to_detect_nonhermetic_paths,
            build_script_toolchains = annotation.build_script_toolchains,
            build_script_tools = annotation.build_script_tools,
            build_script_tags = annotation.build_script_tags,
            build_script_tools_select = annotation.build_script_tools_select,
            build_script_env_select = annotation.build_script_env_select,
            rustc_env = annotation.rustc_env,
            rustc_flags = annotation.rustc_flags,
            rustc_flags_select = annotation.rustc_flags_select,
            data = annotation.data,
            deps = annotation.deps,
            crate_tags = annotation.tags,
            deps_select = deps_select,
            link_deps = annotation.link_deps,
            link_deps_select = annotation.link_deps_select,
            target_compatible_with = annotation.target_compatible_with,
            target_compatible_with_select = annotation.target_compatible_with_select,
            aliases = feature_resolutions.aliases,
            crate_features = annotation.crate_features,
            crate_features_select = feature_resolutions.features_enabled,
            use_legacy_rules_rust_platforms = use_legacy_rules_rust_platforms,
        )

        repo_name = package["target_repo_name"]
        package["target_package_path"] = ""

        if source.startswith("git+"):
            remote, commit = package["git_source"]

            package["target_package_path"] = _git_crate_package_path(annotation, package["strip_prefix"])
            _add_git_crate(git_repos, hub, package, remote, commit)

            git_crate_metadata_repository(
                name = spoke_repo_name(hub_name, crate_name, version),
                package_name = crate_name,
                package_version = version,
                purl = _git_crate_purl(crate_name, version, remote, commit),
                **kwargs
            )
            continue

        kwargs.update(
            additive_build_file = annotation.additive_build_file,
            additive_build_file_content = annotation.additive_build_file_content,
            gen_binaries = annotation.gen_binaries,
            patch_args = annotation.patch_args,
            patch_tool = annotation.patch_tool,
            patches = annotation.patches,
        )
        if source.startswith("sparse+"):
            checksum = package["checksum"]

            qualifiers = {}
            if source != CRATES_IO_REGISTRY:
                qualifiers["repository_url"] = source.split("+", 1)[1]

            crate_repository(
                name = repo_name,
                crate_name = crate_name,
                version = version,
                registry_config = "@%s//:dl" % registry_config_repo_name(hub_name, source),
                sbom_extra_qualifiers = qualifiers,
                checksum = checksum,
                # The repository will need to recompute these, but this lets us avoid serializing them.
                use_home_cargo_credentials = bool(hub.cargo_credentials),
                cargo_config = hub.cargo_config,
                source = source,
                **kwargs
            )
        else:
            local_crate_repository(
                name = repo_name,
                path = package["local_path"],
                **kwargs
            )

    mctx.report_progress("Initializing hub")

    repo_root = _normalize_path(cargo_metadata["workspace_root"])
    workspace_package = _label_directory(cfg.cargo_toml)

    workspace_lints_present = cfg.generate_lint_config and "lints" in workspace_cargo_toml_json.get("workspace", {})
    workspace_manifest_path = paths.join(repo_root, "Cargo.toml")
    lint_configs = {}
    package_lint_targets = []
    lint_packages = cargo_metadata["packages"] if cfg.generate_lint_config else []
    for index, package in enumerate(lint_packages):
        manifest_path = _normalize_path(package["manifest_path"])
        if manifest_path == workspace_manifest_path:
            cargo_toml_json = workspace_cargo_toml_json
        else:
            cargo_toml_json = run_toml2json(mctx, package["manifest_path"])
        lints = cargo_toml_json.get("lints", {})
        package_dir = _manifest_package_dir(manifest_path, repo_root)
        bazel_package = paths.join(workspace_package, package_dir) if package_dir else workspace_package

        if lints.get("workspace") == True:
            if workspace_lints_present:
                lint_configs[bazel_package] = "@%s//:workspace_cargo_lints" % hub_name
        elif lints.get("rust") or lints.get("clippy") or lints.get("rustdoc"):
            if manifest_path == workspace_manifest_path:
                lint_configs[bazel_package] = "@%s//:cargo_lints" % hub_name
            else:
                target_name = "_cargo_lints_%d" % index
                lint_configs[bazel_package] = "@%s//:%s" % (hub_name, target_name)
                package_lint_targets.append((
                    target_name,
                    cargo_toml_lint_flags(cargo_toml_json),
                ))

    hub_contents = []
    for name, versions in resolved_facts.versions_by_name.items():
        default_fq = workspace_resolution.default_workspace_dep_by_name.get(name)
        for version in versions:
            fq = _fq_crate(name, version)
            package = package_by_fq[fq]
            annotation = package["annotation"]
            crate_visibility = package["visibility"]
            target_repo_name = package["target_repo_name"]
            target_package_path = package["target_package_path"]

            hub_contents.append(_render_alias(
                fq,
                _target_label(target_repo_name, target_package_path, name),
                crate_visibility,
            ))
            for binary in annotation.gen_binaries:
                hub_contents.append(_render_alias(
                    "%s__%s" % (fq, binary),
                    _target_label(target_repo_name, target_package_path, binary + "__bin"),
                    crate_visibility,
                ))

            for alias_name, target in sorted(annotation.extra_aliased_targets.items()):
                versioned_alias = "%s-%s" % (alias_name, version)
                hub_contents.append(_render_alias(
                    versioned_alias,
                    _target_label(target_repo_name, target_package_path, target),
                    crate_visibility,
                ))
                if len(versions) == 1:
                    hub_contents.append(_render_alias(alias_name, ":" + versioned_alias, crate_visibility))

            if fq == default_fq:
                hub_contents.append(_render_alias(name, ":" + fq, crate_visibility))
                for binary in annotation.gen_binaries:
                    hub_contents.append(_render_alias(
                        "%s__%s" % (name, binary),
                        ":%s__%s" % (fq, binary),
                        crate_visibility,
                    ))

    for package in cargo_metadata["packages"]:
        package_dir = _manifest_package_dir(package["manifest_path"], repo_root)
        bazel_package = paths.join(workspace_package, package_dir).removesuffix("/")
        if not bazel_package:
            # The alias relies on Bazel's `//foo/bar` -> `//foo/bar:bar`
            # shorthand to pick a target name. When the workspace member is
            # at the bazel workspace root, there's no path component to
            # derive a name from.
            continue
        hub_contents.append(_render_alias(
            _fq_crate(package["name"], package["version"]),
            "@@//" + bazel_package,
            ["//visibility:public"],
        ))

    workspace_deps, conditional_workspace_deps = render_select(
        [],
        workspace_resolution.workspace_dep_labels_by_triple,
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

    hub_contents.append("""load("@rules_rs//rs/private:cargo_lints.bzl", "cargo_lints")""")

    hub_contents.append(_render_cargo_lints_target(
        "cargo_lints",
        cargo_toml_lint_flags(workspace_cargo_toml_json),
    ))

    if workspace_lints_present:
        hub_contents.append(_render_cargo_lints_target(
            "workspace_cargo_lints",
            workspace_cargo_toml_lint_flags(workspace_cargo_toml_json),
        ))

    for target_name, lint_flags in package_lint_targets:
        hub_contents.append(_render_cargo_lints_target(target_name, lint_flags))

    resolved_platforms = set([platform_label(triple, use_legacy_rules_rust_platforms) for triple in platform_triples])

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

def crate_name(package_name = None):
    dep_data = DEP_DATA.get(package_name or native.package_name())
    if not dep_data:
        return None

    return dep_data["crate_name"]

def edition(package_name = None):
    dep_data = DEP_DATA.get(package_name or native.package_name())
    if not dep_data:
        return None

    return dep_data["edition"]

def lint_config(package_name = None):
    dep_data = DEP_DATA.get(package_name or native.package_name())
    if not dep_data:
        return None

    return dep_data.get("lint_config")

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

    data_bzl_contents = render_dep_data(workspace_dep_data(
        cargo_metadata = cargo_metadata,
        feature_resolutions_by_fq_crate = resolved_facts.feature_resolutions_by_fq_crate,
        platforms = platforms,
        repo_root = repo_root,
        workspace_package = workspace_package,
        use_legacy_rules_rust_platforms = use_legacy_rules_rust_platforms,
        lint_configs = lint_configs,
    ))

    _hub_repo(
        name = hub_name,
        contents = {
            "BUILD.bazel": "\n".join(hub_contents),
            "defs.bzl": defs_bzl_contents,
            "data.bzl": data_bzl_contents,
        },
    )

_ALLOW_GIT_ENV = "RULES_RS_ALLOW_GIT"

def _crate_impl(mctx):
    allow_git_override = mctx.getenv(_ALLOW_GIT_ENV)
    if allow_git_override != None and allow_git_override not in ("true", "false"):
        fail("%s must be \"true\" or \"false\", got \"%s\"" % (_ALLOW_GIT_ENV, allow_git_override))

    # TODO(zbarsky): Kick off `cargo` fetch early to mitigate https://github.com/bazelbuild/bazel/issues/26995
    cargo_path = mctx.path(RS_HOST_CARGO_LABEL)

    existing_facts = getattr(mctx, "facts", {}) or {}
    downloader_state = new_downloader_state()
    suggested_annotation_snippet_paths = well_known_annotation_snippet_paths(mctx)

    global_cargo_config = None
    global_use_home_cargo_credentials = False
    for mod in mctx.modules:
        # A dependency's standalone configuration must not override the root module's configuration.
        if not mod.is_root:
            continue

        if len(mod.tags.config) > 1:
            fail("Only one `crate.config` tag may be declared by the root module")

        if mod.tags.config:
            global_cargo_config = mod.tags.config[0].cargo_config_toml
            global_use_home_cargo_credentials = mod.tags.config[0].use_home_cargo_credentials

    hubs = []
    parsed_cargo_configs = {}
    direct_deps = []
    direct_dev_deps = []

    for mod in mctx.modules:
        if not mod.tags.from_cargo:
            if mod.tags.config:
                # The root module can configure dependency closures without declaring a closure.
                # Dependency modules that only declare crate.config remain valid when ignored.
                continue
            fail("`.from_cargo` is required. Please update %s" % mod.name)

        for cfg in mod.tags.from_cargo:
            annotations = build_annotation_map(mod, cfg.name, cfg.platform_triples)
            if mod.is_root:
                if mctx.is_dev_dependency(cfg):
                    direct_dev_deps.append(cfg.name)
                else:
                    direct_deps.append(cfg.name)

            mctx.watch(cfg.cargo_lock)
            mctx.watch(cfg.cargo_toml)

            effective_cargo_config = cfg.cargo_config or global_cargo_config

            cargo_config = {}
            if effective_cargo_config:
                cargo_config = parsed_cargo_configs.get(effective_cargo_config)
                if cargo_config == None:
                    mctx.watch(effective_cargo_config)
                    cargo_config = run_toml2json(mctx, effective_cargo_config)
                    parsed_cargo_configs[effective_cargo_config] = cargo_config

            allow_git_cli = cfg.allow_git_cli if allow_git_override == None else allow_git_override == "true"
            registries = set()
            downloads = []
            packages = run_toml2json(mctx, cfg.cargo_lock).get("package", [])
            for package in packages:
                package["annotation"] = annotation_for(annotations, package["name"], package["version"], cfg.name)
                source = resolve_registry_source(package.get("source"), cargo_config)
                if not source:
                    continue
                package["source"] = source
                if source.startswith("sparse+"):
                    registries.add(source)
                    key = package["name"] + "_" + package["version"]
                elif source.startswith("git+"):
                    # Enforce allow_git_cli even when a cached fact lets us skip the clone.
                    if not allow_git_cli and not source.startswith("git+https://github.com/"):
                        fail("The crate %s %s of the hub `%s` comes from %s, which needs git, and `allow_git_cli` is false." % (
                            package["name"],
                            package["version"],
                            cfg.name,
                            source,
                        ))
                    package["git_source"] = parse_git_url(source)
                    key = source + "_" + package["name"]
                elif source.startswith("path+"):
                    continue
                else:
                    fail("Unknown source " + source)

                package["fact_key"] = key
                if key in existing_facts:
                    continue

                # GitHub workspaces can require a second download for member manifests.
                if source.startswith("git+https://github.com/"):
                    start_github_download(mctx, downloader_state, package)
                else:
                    downloads.append(package)

            use_home_cargo_credentials = cfg.use_home_cargo_credentials or global_use_home_cargo_credentials
            if use_home_cargo_credentials and not effective_cargo_config:
                fail("Must provide cargo_config or crate.config(cargo_config_toml = ...) when using cargo credentials")
            hubs.append(struct(
                cfg = cfg,
                annotations = annotations,
                packages = packages,
                registries = registries,
                downloads = downloads,
                cargo_config = effective_cargo_config,
                cargo_credentials = load_cargo_credentials(mctx, cargo_config) if use_home_cargo_credentials else {},
                use_home_cargo_credentials = use_home_cargo_credentials,
                allow_git_cli = allow_git_cli,
            ))

    for hub in hubs:
        start_crate_downloads(mctx, downloader_state, hub.downloads, hub.cargo_credentials)
        for source in sorted(hub.registries):
            registry_config_repository(
                name = registry_config_repo_name(hub.cfg.name, source),
                source = source,
                cargo_config = hub.cargo_config,
                use_home_cargo_credentials = hub.use_home_cargo_credentials,
            )

    download_metadata_for_git_crates(mctx, downloader_state)

    facts = {}
    git_repos = {}
    platforms_by_triples = {}
    for hub in hubs:
        triples = tuple(hub.cfg.platform_triples)
        if triples not in platforms_by_triples:
            platforms_by_triples[triples] = cargo_platforms(triples)
        _generate_hub_and_spokes(
            mctx,
            hub,
            platforms_by_triples[triples],
            cargo_path = cargo_path,
            suggested_annotation_snippet_paths = suggested_annotation_snippet_paths,
            git_repos = git_repos,
            facts = facts,
        )

    archive_downloads = {}
    for git_repo in git_repos.values():
        url = git_repo["archive_url"]
        if not url:
            continue

        key = "git_archive_integrity:" + url
        if key in existing_facts:
            # Preserve the pin even when this checkout temporarily uses use_git.
            integrity = existing_facts[key]
            if not integrity:
                fail("MODULE.bazel.lock has an empty Git archive checksum for " + url)
            facts[key] = integrity
        elif not git_repo["use_git"] and key not in archive_downloads:
            archive_downloads[key] = mctx.download(
                url,
                "git_archives/%s.tar.gz" % len(archive_downloads),
                # Without a fallback to git, a failed download must fail, so that Bazel reports the cause.
                allow_fail = all([r["allow_git_cli"] for r in git_repos.values() if r["archive_url"] == url and not r["use_git"]]),
                block = False,
            )

    for key, token in archive_downloads.items():
        result = token.wait()
        if result.success:
            facts[key] = result.integrity

    for repo_name, attrs in git_repos.items():
        annotations = attrs.pop("build_annotations")
        attrs["patches"] = list(attrs["patches"])
        git_cargo_workspace_repository(
            name = repo_name,
            additive_build_files = {
                path: annotation.additive_build_file
                for path, annotation in annotations.items()
                if annotation.additive_build_file
            },
            archive_integrity = facts.get("git_archive_integrity:" + attrs["archive_url"], ""),
            build_files = {path: annotation.additive_build_file_content for path, annotation in annotations.items()},
            **attrs
        )

    kwargs = dict(
        root_module_direct_deps = direct_deps,
        root_module_direct_dev_deps = direct_dev_deps,
        reproducible = True,
    )

    if hasattr(mctx, "facts"):
        kwargs["facts"] = facts

    return mctx.extension_metadata(**kwargs)

_config = tag_class(
    doc = "Global Cargo configuration for closures that do not provide their own cargo_config.",
    attrs = {
        "cargo_config_toml": attr.label(
            doc = "The Cargo configuration file applied to every closure without cargo_config.",
            mandatory = True,
        ),
        "use_home_cargo_credentials": attr.bool(
            doc = "Load ~/.cargo/credentials.toml for every Cargo closure.",
        ),
    },
)

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
            mandatory = True,
        ),
        "cargo_lock": attr.label(mandatory = True),
        "cargo_config": attr.label(),
        "allow_git_cli": attr.bool(
            doc = "If false, fail when a Git crate requires the Git CLI (for example, non-GitHub remotes or submodules). " +
                  "`--repo_env=%s=true|false` overrides this setting when set." % _ALLOW_GIT_ENV,
            default = True,
        ),
        "generate_lint_config": attr.bool(
            doc = "If true, generate per-package Cargo lint configuration by reading workspace member manifests.",
            default = False,
        ),
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

_ANNOTATION_COMMON_ATTRS = {
    "crate": attr.string(
        doc = "The name of the crate the annotation is applied to",
        mandatory = True,
    ),
    "version": attr.string(
        doc = "The version of the crate the annotation is applied to. Defaults to all versions.",
        default = "*",
    ),
    "repositories": attr.string_list(
        doc = "Repository names specified by crate.from_cargo(name=...). Defaults to all repositories.",
    ),
}

_ANNOTATION_SELECTABLE_ATTRS = {
    "build_script_data": attr.label_list(
        doc = "Labels to add to a crate's `cargo_build_script::data` attribute.",
    ),
    "build_script_env": attr.string_dict(
        doc = "Environment variables to add to a crate's `cargo_build_script::env` attribute.",
    ),
    "build_script_tools": attr.label_list(
        doc = "Labels to add to a crate's `cargo_build_script::tools` attribute.",
    ),
    "crate_features": attr.string_list(
        doc = "Features to add to a crate's `rust_library::crate_features` attribute.",
    ),
    "deps": attr.label_list(
        doc = "Dependencies to add to a crate's `rust_library::deps` attribute.",
    ),
    "link_deps": attr.label_list(
        doc = "Native dependencies to add to a crate's `rust_library::link_deps` attribute.",
    ),
    "rustc_flags": attr.string_list(
        doc = "Flags to add to a crate's `rust_library::rustc_flags` attribute.",
    ),
    "target_compatible_with": attr.label_list(
        doc = "Constraints to add to a crate's `target_compatible_with` attribute.",
    ),
}

_annotation = tag_class(
    doc = "A collection of extra attributes and settings for a particular crate.",
    attrs = _ANNOTATION_COMMON_ATTRS | _ANNOTATION_SELECTABLE_ATTRS | {
        "additive_build_file": attr.label(
            doc = "A file containing extra contents to write to the bottom of generated BUILD files.",
        ),
        "additive_build_file_content": attr.string(
            doc = "Extra contents to write to the bottom of generated BUILD files.",
        ),
        # "alias_rule": attr.string(
        #     doc = "Alias rule to use instead of `native.alias()`.  Overrides [render_config](#render_config)'s 'default_alias_rule'.",
        # ),
        # "build_script_data_glob": attr.string_list(
        #     doc = "A list of glob patterns to add to a crate's `cargo_build_script::data` attribute",
        # ),
        # "build_script_deps": attr.label_list(
        #     doc = "A list of labels to add to a crate's `cargo_build_script::deps` attribute.",
        # ),
        "build_script_env_files": attr.label_list(
            doc = "Files containing additional environment variables for a crate's `cargo_build_script`.",
            allow_files = True,
        ),
        "allow_build_script_to_detect_nonhermetic_paths": attr.bool(
            default = False,
            doc = "Allow this crate's build script to emit absolute host-system paths in rustc-link-search, rustc-env, or metadata directives.",
        ),
        # "build_script_link_deps": attr.label_list(
        #     doc = "A list of labels to add to a crate's `cargo_build_script::link_deps` attribute.",
        # ),
        # "build_script_rundir": attr.string(
        #     doc = "An override for the build script's rundir attribute.",
        # ),
        # "build_script_rustc_env": attr.string_dict(
        #     doc = "Additional environment variables to set on a crate's `cargo_build_script::env` attribute.",
        # ),
        "build_script_toolchains": attr.label_list(
            doc = "A list of labels to set on a crate's `cargo_build_script::toolchains` attribute.",
        ),
        "build_script_tags": attr.string_list(
            doc = "A list of tags to add to a crate's `cargo_build_script` target.",
        ),
        # "compile_data": attr.label_list(
        # doc = "A list of labels to add to a crate's `rust_library::compile_data` attribute.",
        # ),
        # "compile_data_glob": attr.string_list(
        # doc = "A list of glob patterns to add to a crate's `rust_library::compile_data` attribute.",
        # ),
        # "compile_data_glob_excludes": attr.string_list(
        # doc = "A list of glob patterns to be excllued from a crate's `rust_library::compile_data` attribute.",
        # ),
        "data": attr.label_list(
            doc = "A list of labels to add to a crate's `rust_library::data` attribute.",
        ),
        # "data_glob": attr.string_list(
        #     doc = "A list of glob patterns to add to a crate's `rust_library::data` attribute.",
        # ),
        "deps": attr.label_list(
            doc = "A list of labels to add to a crate's `rust_library::deps` attribute.",
        ),
        "tags": attr.string_list(
            doc = "A list of tags to add to a crate's generated targets.",
        ),
        # "disable_pipelining": attr.bool(
        #     doc = "If True, disables pipelining for library targets for this crate.",
        # ),
        "extra_aliased_targets": attr.string_dict(
            doc = "A dictionary mapping alias names in the hub repository to target names in the generated crate package.",
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
        "rustc_env": attr.string_dict(
            doc = "Additional variables to set on a crate's `rust_library::rustc_env` attribute.",
        ),
        # "rustc_env_files": attr.label_list(
        #     doc = "A list of labels to set on a crate's `rust_library::rustc_env_files` attribute.",
        # ),
        # "shallow_since": attr.string(
        #     doc = "An optional timestamp used for crates originating from a git repository instead of a crate registry. This flag optimizes fetching the source code.",
        # ),
        "strip_prefix": attr.string(),
        "use_git": attr.bool(
            doc = "For a Git crate, fetch the complete Git checkout instead of a GitHub source archive. " +
                  "Applies to all crates sharing this Git commit in the hub. Fails if allow_git_cli is false after any RULES_RS_ALLOW_GIT override.",
        ),
        "visibility": attr.label_list(
            default = ["//visibility:public"],
            doc = "Visibility of generated libraries, procedural macros, binaries, and hub aliases. Labels resolve in the declaring module. Generated dependencies within the Cargo closure retain access; package metadata remains public.",
        ),
        "workspace_cargo_toml": attr.string(
            doc = "For crates from git, the ruleset assumes the (workspace) Cargo.toml is in the repo root. This attribute overrides the assumption.",
            default = "Cargo.toml",
        ),
    },
)

_annotation_select = tag_class(
    doc = "A collection of build attributes applied to a crate for selected platform triples. Source attributes such as patches and workspace_cargo_toml belong on crate.annotation.",
    attrs = _ANNOTATION_COMMON_ATTRS | {
        "triples": attr.string_list(
            doc = "Platform triples to which the annotation applies.",
            mandatory = True,
        ),
    } | _ANNOTATION_SELECTABLE_ATTRS,
)

crate = module_extension(
    implementation = _crate_impl,
    tag_classes = {
        "annotation": _annotation,
        "annotation_select": _annotation_select,
        "config": _config,
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
