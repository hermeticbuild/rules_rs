"""Cargo module extension configuration and orchestration."""

load("@bazel_lib//lib:repo_utils.bzl", "repo_utils")
load("@bazel_skylib//lib:paths.bzl", "paths")
load("@rs_rust_host_tools//:defs.bzl", "RS_HOST_CARGO_LABEL")
load("//rs/private:annotations.bzl", "annotation_for", "build_annotation_map", "well_known_annotation_snippet_paths")
load("//rs/private:cargo_credentials.bzl", "load_cargo_credentials")
load("//rs/private:crate_coalescing.bzl", _finalize_coalescer = "finalize_coalescer")
load("//rs/private:crate_collection_order.bzl", _coalescer_collection_order = "coalescer_collection_order")
load("//rs/private:crate_hub_generation.bzl", _additive_build_file_content = "additive_build_file_content", _generate_hub_and_spokes = "generate_hub_and_spokes")
load("//rs/private:crate_hub_resolution.bzl", _resolve_hub = "resolve_hub")
load("//rs/private:crate_identity.bzl", _normalize_git_remote = "normalize_git_remote")
load("//rs/private:crate_metadata.bzl", _add_git_build_file = "add_git_build_file", _add_registry_fetch_config = "add_registry_fetch_config", _git_checkout_fingerprint = "git_checkout_fingerprint", _record_hub_config = "record_hub_config", _registry_metadata_prefixes = "registry_metadata_prefixes", _selected_registry_credentials = "selected_registry_credentials")
load("//rs/private:downloader.bzl", "download_metadata_for_git_crates", "download_registry_config", "new_downloader_state", "parse_git_url", "start_crate_registry_downloads", "start_github_downloads")
load("//rs/private:git_cargo_workspace_repository.bzl", "git_cargo_workspace_repository")
load("//rs/private:registry_utils.bzl", "CRATES_IO_REGISTRY", "resolve_registry_source")
load("//rs/private:toml2json.bzl", "run_toml2json")

_label_list_dict = getattr(attr, "label_list_dict", attr.string_list_dict)

def _crate_impl(mctx):
    # TODO(zbarsky): Kick off `cargo` fetch early to mitigate https://github.com/bazelbuild/bazel/issues/26995
    cargo_path = mctx.path(RS_HOST_CARGO_LABEL)

    # Force the hermetic toml2json repository to be available before resolution.
    toml2json = mctx.path(Label("@toml2json_%s//file:downloaded" % repo_utils.platform(mctx)))

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

    packages_by_hub_name = {}
    cargo_toml_by_hub_name = {}
    cargo_config_by_hub_name = {}
    parsed_cargo_configs = {}
    registry_fetch_configs = {}
    annotations_by_hub_name = {}
    configs_by_hub_name = {}

    for mod in mctx.modules:
        if not mod.tags.from_cargo:
            if mod.tags.config:
                # The root module can configure dependency closures without declaring a closure.
                # Dependency modules that only declare crate.config remain valid when ignored.
                continue
            fail("`.from_cargo` is required. Please update %s" % mod.name)

        for cfg in mod.tags.from_cargo:
            _record_hub_config(configs_by_hub_name, cfg, mod)
            annotations = build_annotation_map(mod, cfg.name, cfg.platform_triples)
            annotations_by_hub_name[cfg.name] = annotations
            mctx.watch(cfg.cargo_lock)
            mctx.watch(cfg.cargo_toml)

            effective_cargo_config = cfg.cargo_config or global_cargo_config
            cargo_config_by_hub_name[cfg.name] = effective_cargo_config

            cargo_config = {}
            if effective_cargo_config:
                cargo_config_key = str(effective_cargo_config)
                cargo_config = parsed_cargo_configs.get(cargo_config_key)
                if cargo_config == None:
                    mctx.watch(effective_cargo_config)
                    cargo_config = run_toml2json(mctx, effective_cargo_config)
                    parsed_cargo_configs[cargo_config_key] = cargo_config

            cargo_toml_by_hub_name[cfg.name] = run_toml2json(mctx, cfg.cargo_toml)
            cargo_lock = run_toml2json(mctx, cfg.cargo_lock)
            parsed_packages = cargo_lock.get("package", [])
            for package in parsed_packages:
                package["hub_name"] = cfg.name
                source = resolve_registry_source(package.get("source"), cargo_config)
                if source:
                    package["source"] = source
            packages_by_hub_name[cfg.name] = parsed_packages

            # Process git downloads first because they may require a followup download if the repo is a workspace,
            # so we want to enqueue them early so they don't get delayed by 1-shot registry downloads.
            start_github_downloads(mctx, downloader_state, annotations, parsed_packages)

    configs = [configs_by_hub_name[name] for name in sorted(configs_by_hub_name)]
    for config in configs:
        cfg = config.cfg
        effective_cargo_config = cargo_config_by_hub_name[cfg.name]
        use_home_cargo_credentials = cfg.use_home_cargo_credentials or global_use_home_cargo_credentials

        if use_home_cargo_credentials:
            if not effective_cargo_config:
                fail("Must provide cargo_config or crate.config(cargo_config_toml = ...) when using cargo credentials")

            cargo_credentials = load_cargo_credentials(mctx, effective_cargo_config)
        else:
            cargo_credentials = {}

        packages = packages_by_hub_name[cfg.name]
        registry_sources = set()

        for package in packages:
            source = package.get("source")
            if source == "registry+https://github.com/rust-lang/crates.io-index":
                source = CRATES_IO_REGISTRY
                package["source"] = source

            if source and source.startswith("sparse+"):
                registry_sources.add(source)

        for source in sorted(registry_sources):
            _add_registry_fetch_config(
                registry_fetch_configs,
                cfg.name,
                source,
                effective_cargo_config,
                use_home_cargo_credentials,
                cargo_credentials,
            )

    registry_metadata_prefixes = _registry_metadata_prefixes(registry_fetch_configs)
    for index, source in enumerate(sorted(registry_fetch_configs)):
        fetch_config = registry_fetch_configs[source]
        fetch_config.update(download_registry_config(
            mctx,
            source = source,
            cargo_credentials = {source: fetch_config["token"]} if fetch_config["token"] else {},
            output_prefix = "registry_config_%d" % index,
        ))

    registry_credentials = _selected_registry_credentials(registry_fetch_configs)
    for config in configs:
        cfg = config.cfg
        start_crate_registry_downloads(
            mctx,
            downloader_state,
            build_annotation_map(config.mod, cfg.name, cfg.platform_triples),
            packages_by_hub_name[cfg.name],
            registry_metadata_prefixes,
            registry_credentials,
            cfg.debug,
        )

    for fetch_state in downloader_state.in_flight_git_crate_fetches_by_url.values():
        fetch_state.download_token.wait()

    download_metadata_for_git_crates(mctx, downloader_state, annotations_by_hub_name)

    # Resolve each Cargo graph exactly once. The returned plans retain all
    # expensive metadata, fact, feature, workspace, and platform resolution.
    resolved_configs = []
    for config in configs:
        cfg = config.cfg
        plan = _resolve_hub(
            mctx,
            cfg.name,
            build_annotation_map(config.mod, cfg.name, cfg.platform_triples),
            cargo_path,
            cfg.cargo_lock,
            cargo_config_by_hub_name[cfg.name],
            cargo_toml_by_hub_name[cfg.name],
            packages_by_hub_name[cfg.name],
            cfg.platform_triples,
            cfg.validate_lockfile,
            cfg.debug,
            cfg.generate_lint_config,
            cfg.use_legacy_rules_rust_platforms,
        )
        resolved_configs.append({
            "config": config,
            "plan": plan,
        })

    coalescer = {
        "assignments": {},
        "identities_by_repo": {},
        "packages": {},
    }

    # First classify every occurrence. No repository is created until all
    # additive feature and dependency inputs have been merged into their final
    # compatibility classes.
    for occurrence in _coalescer_collection_order(resolved_configs):
        _generate_hub_and_spokes(
            mctx,
            occurrence["plan"],
            suggested_annotation_snippet_paths,
            registry_fetch_configs,
            coalescer,
            materialize = False,
            packages_to_process = [occurrence["package"]],
        )
    _finalize_coalescer(coalescer)

    facts = {}
    fact_hubs = {}
    direct_deps = []
    direct_dev_deps = []
    for resolved in resolved_configs:
        config = resolved["config"]
        cfg = config.cfg
        plan = resolved["plan"]

        if config.mod.is_root:
            if mctx.is_dev_dependency(cfg):
                direct_dev_deps.append(cfg.name)
            else:
                direct_deps.append(cfg.name)

        for key, value in plan["facts"].items():
            previous = facts.get(key)
            if previous != None and previous != value:
                fail("Conflicting cached Cargo metadata fact %s in hubs %s and %s" % (
                    key,
                    fact_hubs[key],
                    cfg.name,
                ))
            if previous == None:
                fact_hubs[key] = cfg.name
            facts[key] = value
        _generate_hub_and_spokes(
            mctx,
            plan,
            suggested_annotation_snippet_paths,
            registry_fetch_configs,
            coalescer,
            materialize = True,
        )

    # Lay down git source repositories with generated per-crate BUILD overlays.
    # target_repo_name was assigned explicitly from the compatibility class;
    # no repository-name-prefix convention is used here.
    git_repos = {}
    for resolved in resolved_configs:
        plan = resolved["plan"]
        hub_name = plan["hub_name"]
        annotations = plan["annotations"]
        for package in plan["packages"]:
            source = package.get("source", "")
            if not source.startswith("git+"):
                continue

            remote, commit = parse_git_url(source)
            annotation = annotation_for(annotations, package["name"], package["version"], hub_name)
            checkout_fingerprint = _git_checkout_fingerprint(annotation)
            package_path = package["target_package_path"]
            spoke_repo_name = package["spoke_repo_name"]
            repo_name = package["target_repo_name"]

            git_repo = git_repos.get(repo_name)
            if not git_repo:
                git_repo = {
                    "build_files": {},
                    "checkout_fingerprint": checkout_fingerprint,
                    "gen_binaries": {},
                    "commit": commit,
                    "first_hub": hub_name,
                    "patch_args": annotation.patch_args,
                    "patch_tool": annotation.patch_tool or "",
                    "patches": annotation.patches,
                    "remote": remote,
                    "workspace_cargo_toml": annotation.workspace_cargo_toml,
                    "crate_bzls": {},
                }
                git_repos[repo_name] = git_repo
            elif _normalize_git_remote(git_repo["remote"]) != _normalize_git_remote(remote) or git_repo["commit"] != commit:
                fail("Git crates from %s at %s and %s at %s produce the same repository name %s" % (
                    git_repo["remote"],
                    git_repo["commit"],
                    remote,
                    commit,
                    repo_name,
                ))
            elif git_repo["checkout_fingerprint"] != checkout_fingerprint:
                fail("Git checkout identity collision for repository %s" % repo_name)

            build_file_path = paths.join(package_path, "BUILD.bazel") if package_path else "BUILD.bazel"
            additive_build_file_content = _additive_build_file_content(mctx, annotation)
            _add_git_build_file(
                git_repo,
                source,
                build_file_path,
                additive_build_file_content,
                hub_name,
            )
            git_repo["crate_bzls"][build_file_path] = "@%s//:crate.bzl" % spoke_repo_name
            if package["coalesced_gen_binaries"]:
                git_repo["gen_binaries"][build_file_path] = package["coalesced_gen_binaries"]

    for repo_name in sorted(git_repos):
        git_repo = git_repos[repo_name]
        kwargs = {}
        if git_repo["gen_binaries"]:
            kwargs["gen_binaries"] = git_repo["gen_binaries"]

        git_cargo_workspace_repository(
            name = repo_name,
            build_files = git_repo["build_files"],
            commit = git_repo["commit"],
            crate_bzls = git_repo["crate_bzls"],
            patch_args = git_repo["patch_args"],
            patch_tool = git_repo["patch_tool"],
            patches = git_repo["patches"],
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
        ),
        "cargo_lock": attr.label(),
        "cargo_config": attr.label(),
        "generate_lint_config": attr.bool(
            doc = "If true, generate per-package Cargo lint configuration by reading workspace member manifests.",
            default = False,
        ),
        "use_home_cargo_credentials": attr.bool(
            doc = "If set, load `$CARGO_HOME/credentials.toml` or `~/.cargo/credentials.toml` and authenticate registry requests whose sparse `config.json` declares `auth-required`.",
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
    "rustc_flags": attr.string_list(
        doc = "Flags to add to a crate's `rust_library::rustc_flags` attribute.",
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
        "link_deps": attr.string_list(
            doc = "Labels to add to a crate's `rust_library::link_deps` attribute.",
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
