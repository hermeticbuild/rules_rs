"""Crate hub generation."""

load("@bazel_skylib//lib:paths.bzl", "paths")
load("//rs/private:annotations.bzl", "annotation_for")
load("//rs/private:cargo_workspace_graph.bzl", "platform_label", "render_dep_data", "render_string_list", "workspace_dep_data", _fq_crate = "fq_crate", _manifest_package_dir = "manifest_package_dir", _normalize_path = "normalize_path", _select = "select_items")
load("//rs/private:crate_coalescing.bzl", _coalesce_spoke = "coalesce_spoke", _coalesced_compilation_fingerprint = "coalesced_compilation_fingerprint", _coalesced_compilation_kwargs = "coalesced_compilation_kwargs")
load("//rs/private:crate_compatibility.bzl", _compilation_fingerprint = "compilation_fingerprint")
load("//rs/private:crate_dependency_order.bzl", _hub_dep_fq = "hub_dep_fq")
load("//rs/private:crate_hub_resolution.bzl", _date = "date")
load("//rs/private:crate_identity.bzl", _canonical_git_repo = "canonical_git_repo", _crate_identity = "crate_identity", _spoke_repo = "spoke_repo")
load("//rs/private:crate_metadata.bzl", _git_checkout_fingerprint = "git_checkout_fingerprint")
load("//rs/private:crate_repository.bzl", "crate_repository", "local_crate_repository")
load("//rs/private:downloader.bzl", "parse_git_url")
load("//rs/private:git_crate_metadata_repository.bzl", "git_crate_metadata_repository")
load("//rs/private:lint_flags.bzl", "cargo_toml_lint_flags", "workspace_cargo_toml_lint_flags")
load("//rs/private:registry_utils.bzl", "CRATES_IO_REGISTRY")
load("//rs/private:repository_utils.bzl", "render_select")
load("//rs/private:toml2json.bzl", "run_toml2json")

def _canonical_dep_label(label, hub_name, package_by_fq):
    dep_fq = _hub_dep_fq(label, hub_name)
    package = package_by_fq.get(dep_fq)
    if not package:
        return label
    return _target_label(
        package["target_repo_name"],
        package["target_package_path"],
        package["name"],
    )

def _canonical_dep_select(items, hub_name, package_by_fq):
    return {
        triple: [
            _canonical_dep_label(label, hub_name, package_by_fq)
            for label in labels
        ]
        for triple, labels in items.items()
    }

def _canonical_aliases(aliases, hub_name, package_by_fq):
    return {
        _canonical_dep_label(label, hub_name, package_by_fq): alias
        for label, alias in aliases.items()
    }

def _external_repo_for_git_source(hub_name, remote, commit, checkout_fingerprint):
    return hub_name + "__" + _canonical_git_repo(remote, commit, checkout_fingerprint)

def _git_crate_purl(name, version, remote, commit):
    return "pkg:cargo/%s@%s?vcs_url=git+%s@%s" % (name, version, remote, commit)

def _render_ordered_string_list(items):
    """Like _render_string_list but preserves insertion order."""
    return ",\n        ".join([repr(item) for item in items])

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

def git_crate_package_path(annotation, strip_prefix):
    workspace_dir = annotation.workspace_cargo_toml.removesuffix("Cargo.toml").removesuffix("/")
    crate_dir = (strip_prefix or "").removeprefix("./").removesuffix("/")

    if workspace_dir and crate_dir:
        return _normalize_path(paths.normalize(paths.join(workspace_dir, crate_dir)))
    if workspace_dir:
        return _normalize_path(workspace_dir)
    return _normalize_path(crate_dir)

_git_crate_package_path = git_crate_package_path

def _target_label(repo_name, package_path, target):
    if package_path:
        return "@%s//%s:%s" % (repo_name, package_path, target)
    return "@%s//:%s" % (repo_name, target)

def additive_build_file_content(mctx, annotation):
    content = ""
    if annotation.additive_build_file:
        content += mctx.read(annotation.additive_build_file)
    content += annotation.additive_build_file_content
    return content

_additive_build_file_content = additive_build_file_content

def generate_hub_and_spokes(
        mctx,
        plan,
        suggested_annotation_snippet_paths,
        registry_fetch_configs,
        coalescer,
        materialize,
        packages_to_process = None):
    """Collects spoke classes or materializes a previously resolved hub plan."""
    hub_name = plan["hub_name"]
    annotations = plan["annotations"]
    cargo_lock_path = plan["cargo_lock_path"]
    cargo_metadata = plan["cargo_metadata"]
    cfg_match_cache = plan["cfg_match_cache"]
    feature_resolutions_by_fq_crate = plan["feature_resolutions_by_fq_crate"]
    package_by_fq = plan["package_by_fq"]
    packages = plan["packages"] if packages_to_process == None else packages_to_process
    platform_cfg_attrs = plan["platform_cfg_attrs"]
    platform_triples = plan["platform_triples"]
    repo_root = plan["repo_root"]
    use_legacy_rules_rust_platforms = plan["use_legacy_rules_rust_platforms"]
    versions_by_name = plan["versions_by_name"]
    workspace_cargo_toml_json = plan["workspace_cargo_toml_json"]
    workspace_dep_labels_by_triple = plan["workspace_dep_labels_by_triple"]
    workspace_dep_versions_by_name = plan["workspace_dep_versions_by_name"]
    workspace_package = plan["workspace_package"]

    if materialize:
        mctx.report_progress("Initializing spokes for %s" % hub_name)

    for package in packages:
        crate_name = package["name"]
        version = package["version"]
        source = package["source"]

        feature_resolutions = feature_resolutions_by_fq_crate[_fq_crate(crate_name, version)]

        annotation = annotation_for(annotations, crate_name, version, hub_name)
        suggested_annotation = None
        if materialize and annotation.gen_build_script == "auto":
            snippet_path = suggested_annotation_snippet_paths.get(crate_name)
            if snippet_path:
                suggested_annotation = mctx.read(snippet_path).strip()

        if suggested_annotation:
            print("""
WARNING: A well-known crate annotation exists to make builds of {crate} more hermetic! Apply the following to your MODULE.bazel:

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
            ))

        kwargs = dict(
            hub_name = hub_name,
            gen_build_script = annotation.gen_build_script,
            build_script_deps = [],
            build_script_deps_select = _canonical_dep_select(
                _select(feature_resolutions.build_deps),
                hub_name,
                package_by_fq,
            ),
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
            deps_select = _canonical_dep_select(
                _select(feature_resolutions.deps),
                hub_name,
                package_by_fq,
            ),
            aliases = _canonical_aliases(
                feature_resolutions.aliases,
                hub_name,
                package_by_fq,
            ),
            link_deps = annotation.link_deps,
            crate_features = annotation.crate_features,
            crate_features_select = _select(feature_resolutions.features_enabled),
            platform_triples = platform_triples,
            use_legacy_rules_rust_platforms = use_legacy_rules_rust_platforms,
        )

        if source.startswith("sparse+"):
            fetch_config = registry_fetch_configs[source]
            checksum = package["checksum"]
            fingerprint = _compilation_fingerprint(package, annotation, kwargs, platform_triples)
            repo_name, class_index, create_repo = _coalesce_spoke(coalescer, package, "", hub_name, fingerprint)
            finalized_fingerprint = _coalesced_compilation_fingerprint(
                coalescer,
                package,
                "",
                hub_name,
                fingerprint,
            )
            kwargs = _coalesced_compilation_kwargs(coalescer, package, "", hub_name, kwargs)
            crate_identity = _crate_identity(package, "")
            package["coalesced_gen_binaries"] = finalized_fingerprint["union"]["gen_binaries"]
            package["spoke_repo_name"] = repo_name
            package["target_repo_name"] = repo_name
            package["target_package_path"] = ""

            if not materialize or not create_repo:
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
                registry_auth_required = fetch_config["auth_required"],
                registry_dl = fetch_config["dl"],
                sbom_extra_qualifiers = qualifiers,
                checksum = checksum,
                gen_binaries = finalized_fingerprint["union"]["gen_binaries"],
                patch_args = annotation.patch_args,
                patch_tool = annotation.patch_tool,
                patches = annotation.patches,
                # The repository will need to recompute these, but this lets us avoid serializing them.
                use_home_cargo_credentials = fetch_config["use_home_cargo_credentials"],
                cargo_config = fetch_config["cargo_config"],
                source = source,
                crate_identity = crate_identity,
                **kwargs
            )
        elif source.startswith("path+"):
            repo_name = _spoke_repo(hub_name, crate_name, version)
            package["spoke_repo_name"] = repo_name
            package["target_repo_name"] = repo_name
            package["target_package_path"] = ""

            if not materialize:
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
            checkout_fingerprint = _git_checkout_fingerprint(annotation)

            package_path = _git_crate_package_path(annotation, package.get("strip_prefix"))
            fingerprint = _compilation_fingerprint(package, annotation, kwargs, platform_triples)
            repo_name, class_index, create_repo = _coalesce_spoke(coalescer, package, package_path, hub_name, fingerprint)
            finalized_fingerprint = _coalesced_compilation_fingerprint(
                coalescer,
                package,
                package_path,
                hub_name,
                fingerprint,
            )
            kwargs = _coalesced_compilation_kwargs(coalescer, package, package_path, hub_name, kwargs)
            crate_identity = _crate_identity(package, package_path)
            package["coalesced_gen_binaries"] = finalized_fingerprint["union"]["gen_binaries"]
            package["spoke_repo_name"] = repo_name
            if class_index == 0:
                package["target_repo_name"] = _canonical_git_repo(remote, commit, checkout_fingerprint)
            else:
                package["target_repo_name"] = _external_repo_for_git_source(repo_name, remote, commit, checkout_fingerprint)
            package["target_package_path"] = package_path

            if not materialize or not create_repo:
                continue

            git_crate_metadata_repository(
                name = repo_name,
                package_name = crate_name,
                package_version = version,
                purl = _git_crate_purl(crate_name, version, remote, commit),
                crate_identity = crate_identity,
                **kwargs
            )
        else:
            fail("Unknown source %s for crate %s" % (source, crate_name))

    if not materialize:
        return

    _date(mctx, "created repos")

    mctx.report_progress("Initializing hub")

    generate_lint_config = plan["generate_lint_config"]
    workspace_lints_present = generate_lint_config and "lints" in workspace_cargo_toml_json.get("workspace", {})
    workspace_manifest_path = paths.join(repo_root, "Cargo.toml")
    lint_configs = {}
    package_lint_targets = []
    lint_packages = cargo_metadata["packages"] if generate_lint_config else []
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
    for name, versions in versions_by_name.items():
        for version in versions:
            annotation = annotation_for(annotations, name, version, hub_name)
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
            annotation = annotation_for(annotations, name, default_version, hub_name)

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

        if len(versions) == 1:
            version = versions[0]
            annotation = annotation_for(annotations, name, version, hub_name)
            for alias_name in sorted(annotation.extra_aliased_targets.keys()):
                hub_contents.append("""
alias(
    name = "{alias_name}",
    actual = ":{alias_name}-{version}",
)""".format(
                    alias_name = alias_name,
                    version = version,
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
        hub_contents.append("""
alias(
    name = "{name}-{version}",
    actual = "@@//{bazel_package}",
)""".format(
            name = package["name"],
            version = package["version"],
            bazel_package = bazel_package,
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

    _date(mctx, "done")

    data_bzl_contents = render_dep_data(workspace_dep_data(
        cargo_metadata = cargo_metadata,
        feature_resolutions_by_fq_crate = feature_resolutions_by_fq_crate,
        platform_triples = platform_triples,
        platform_cfg_attrs = platform_cfg_attrs,
        cfg_match_cache = cfg_match_cache,
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

    return plan["facts"]

_generate_hub_and_spokes = generate_hub_and_spokes

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
