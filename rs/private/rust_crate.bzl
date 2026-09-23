load("@package_metadata//rules:package_metadata.bzl", "package_metadata")
load(
    "@rules_rust//rust/private:rust.bzl",
    _rust_library = "rust_library",
    _rust_proc_macro = "rust_proc_macro",
)
load("//rs:rust_binary.bzl", "rust_binary")
load("//rs:rust_library.bzl", "rust_library")
load("//rs:rust_proc_macro.bzl", "rust_proc_macro")
load(":cargo_build_script_variants.bzl", "cargo_build_script_for_configurations")
load(":cargo_select.bzl", "cargo_select")

def rust_crate(
        name,
        crate_name,
        purl,
        version,
        configurations,
        cargo_target_triple_map,
        hub_name,
        deps,
        link_deps,
        data,
        crate_root,
        edition,
        rustc_flags,
        tags,
        links,
        build_script,
        build_script_data,
        build_script_env,
        build_script_env_files,
        allow_build_script_to_detect_nonhermetic_paths,
        build_script_toolchains,
        build_script_tools,
        build_script_tags,
        is_proc_macro,
        has_lib,
        binaries,
        use_legacy_rules_rust_platforms,
        extra_compile_data = [],
        rustc_env = {},
        skip_deps_verification = False):
    package_metadata_name = name + "_package_metadata"
    package_metadata(
        name = package_metadata_name,
        purl = purl,
        visibility = ["//visibility:public"],
    )

    if deps:
        deps = set([native.package_relative_label(dep) for dep in deps])
        resolved_deps = {}
        for cargo_target_triple, configuration in configurations.items():
            resolved_deps[cargo_target_triple] = {}
            for platform_triple, labels in configuration["deps_by_triple"].items():
                selected = []
                for label in labels:
                    label = native.package_relative_label(label)
                    if label not in deps:
                        selected.append(label)
                resolved_deps[cargo_target_triple][platform_triple] = selected
        deps = list(deps)
    else:
        resolved_deps = {
            cargo_target_triple: {platform_triple: list(deps) for platform_triple, deps in configuration["deps_by_triple"].items()}
            for cargo_target_triple, configuration in configurations.items()
        }
    deps = deps + cargo_select(resolved_deps, hub_name, use_legacy_rules_rust_platforms, default = [])
    crate_features = cargo_select(
        {cargo_target_triple: configuration["crate_features_by_triple"] for cargo_target_triple, configuration in configurations.items()},
        hub_name,
        use_legacy_rules_rust_platforms,
        default = [],
    )
    aliases = cargo_select(
        {
            cargo_target_triple: {
                platform_triple: {
                    dep: alias
                    for dep, alias in deps.items()
                    if alias
                }
                for platform_triple, deps in configuration["deps_by_triple"].items()
            }
            for cargo_target_triple, configuration in configurations.items()
        },
        hub_name,
        use_legacy_rules_rust_platforms,
        default = {},
    )
    target_compatible_with = cargo_select(
        {
            cargo_target_triple: {platform_triple: [] for platform_triple in configuration["crate_features_by_triple"]}
            for cargo_target_triple, configuration in configurations.items()
        },
        hub_name,
        use_legacy_rules_rust_platforms,
        default = ["@platforms//:incompatible"],
    ) if hub_name else []

    compile_data = native.glob(
        include = ["**"],
        exclude = [
            "**/* *",
            ".git",
            ".tmp_git_root/**/*",
            "BUILD",
            "BUILD.bazel",
            "REPO.bazel",
            "Cargo.toml.orig",
            "WORKSPACE",
            "WORKSPACE.bazel",
        ],
        allow_empty = True,
    ) + extra_compile_data

    srcs = native.glob(
        include = ["**/*.rs"],
        allow_empty = True,
    )

    default_tags = [
        "crate-name=" + name,
        "manual",
        "noclippy",
        "norustfmt",
    ]
    crate_tags = default_tags + tags

    if build_script:
        deps = deps + cargo_build_script_for_configurations(
            configurations = configurations,
            hub_name = hub_name,
            name = "_bs",
            use_legacy_rules_rust_platforms = use_legacy_rules_rust_platforms,
            compile_data = compile_data,
            crate_name = "build_script_build",
            crate_root = build_script,
            links = links,
            data = compile_data + build_script_data,
            link_deps = deps,
            build_script_env = build_script_env,
            allow_build_script_to_detect_nonhermetic_paths = allow_build_script_to_detect_nonhermetic_paths,
            build_script_env_files = build_script_env_files,
            toolchains = build_script_toolchains,
            tools = build_script_tools,
            edition = edition,
            pkg_name = crate_name,
            rustc_env = rustc_env,
            rustc_env_files = ["cargo_toml_env_vars.env"],
            rustc_flags = ["--cap-lints=allow"],
            srcs = srcs,
            target_compatible_with = target_compatible_with,
            tags = crate_tags + build_script_tags,
            version = version,
        )

    if not has_lib:
        # Keep the hub's library label incompatible for binary-only crates.
        native.filegroup(
            name = name,
            tags = crate_tags,
            target_compatible_with = ["@platforms//:incompatible"],
            visibility = ["//visibility:public"],
        )
    else:
        kwargs = dict(
            name = name,
            cargo_target_triple_map = cargo_target_triple_map,
            crate_name = crate_name,
            version = version,
            srcs = srcs,
            compile_data = compile_data,
            aliases = aliases,
            deps = deps,
            data = data,
            crate_features = crate_features,
            crate_root = crate_root,
            edition = edition,
            rustc_env = rustc_env,
            rustc_env_files = ["cargo_toml_env_vars.env"],
            rustc_flags = rustc_flags + ["--cap-lints=allow"],
            tags = crate_tags,
            target_compatible_with = target_compatible_with,
            package_metadata = [package_metadata_name],
            skip_deps_verification = skip_deps_verification,
            visibility = ["//visibility:public"],
            skip_per_crate_rustc_flags = True,
        )

        if is_proc_macro:
            # rules_rust's rust_proc_macro rule has no link_deps attribute.
            # Preserve link_deps for any binaries generated by the same package.
            (_rust_proc_macro if skip_deps_verification else rust_proc_macro)(**kwargs)
        else:
            kwargs["link_deps"] = link_deps
            (_rust_library if skip_deps_verification else rust_library)(**kwargs)

    if binaries and has_lib:
        deps = [name] + deps
    for binary, crate_root in binaries.items():
        rust_binary(
            name = binary + "__bin",
            cargo_target_triple_map = cargo_target_triple_map,
            compile_data = compile_data,
            aliases = aliases,
            deps = deps,
            link_deps = link_deps,
            data = data,
            crate_features = crate_features,
            crate_root = crate_root,
            edition = edition,
            rustc_env = rustc_env,
            rustc_env_files = ["cargo_toml_env_vars.env"],
            rustc_flags = rustc_flags + ["--cap-lints=allow"],
            srcs = srcs,
            tags = crate_tags,
            target_compatible_with = target_compatible_with,
            version = version,
            visibility = ["//visibility:public"],
        )
