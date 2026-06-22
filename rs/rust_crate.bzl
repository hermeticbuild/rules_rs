load("@package_metadata//rules:package_metadata.bzl", "package_metadata")
load(
    "@rules_rust//rust/private:rust.bzl",
    _rust_library = "rust_library",
    _rust_proc_macro = "rust_proc_macro",
)
load("//rs:cargo_build_script.bzl", "cargo_build_script")
load("//rs:rust_binary.bzl", "rust_binary")
load("//rs:rust_library.bzl", "rust_library")
load("//rs:rust_proc_macro.bzl", "rust_proc_macro")

def _platform(triple, use_legacy_rules_rust_platforms):
    if use_legacy_rules_rust_platforms:
        return "@rules_rust//rust/platform:" + triple.replace("-musl", "-gnu").replace("-gnullvm", "-msvc")
    return "@rules_rs//rs/platforms/config:" + triple

def _rust_crate_impl(
        name,
        crate_name,
        version,
        aliases,
        deps,
        data,
        crate_features,
        triples,
        conditional_crate_features,
        crate_root,
        edition,
        rustc_flags,
        tags,
        target_compatible_with,
        package_metadata_name,
        links,
        build_script,
        build_script_name,
        build_script_data,
        build_deps,
        build_script_env,
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
        "crate-name=" + crate_name,
        "manual",
        "noclippy",
        "norustfmt",
    ]
    crate_tags = default_tags + tags
    build_script_target_tags = crate_tags + build_script_tags

    if build_script:
        build_script_kwargs = dict(
            deps = build_deps,
            aliases = aliases,
            compile_data = compile_data,
            crate_name = "build_script_build",
            crate_root = build_script,
            links = links,
            data = compile_data + build_script_data,
            link_deps = deps,
            build_script_env = build_script_env,
            allow_build_script_to_detect_nonhermetic_paths = allow_build_script_to_detect_nonhermetic_paths,
            build_script_env_files = ["cargo_toml_env_vars.env"],
            toolchains = build_script_toolchains,
            tools = build_script_tools,
            edition = edition,
            pkg_name = crate_name,
            rustc_env = rustc_env,
            rustc_env_files = ["cargo_toml_env_vars.env"],
            rustc_flags = ["--cap-lints=allow"],
            srcs = srcs,
            target_compatible_with = target_compatible_with,
            tags = build_script_target_tags + ["manual"],
            version = version,
        )

        if conditional_crate_features:
            branches = {}

            # The build script is cfg-exec, but the features must be selected according to the target.
            # Only stamp out one target per triple when there are per-platform feature deltas.
            for triple in triples:
                triple_build_script_name = build_script_name + "_" + triple
                branches[_platform(triple, use_legacy_rules_rust_platforms)] = triple_build_script_name

                cargo_build_script(
                    name = triple_build_script_name,
                    crate_features = crate_features + conditional_crate_features.get(triple, []),
                    **build_script_kwargs
                )

            native.alias(
                name = build_script_name,
                actual = select(branches),
                tags = build_script_target_tags,
            )

        else:
            cargo_build_script(
                name = build_script_name,
                crate_features = crate_features,
                **build_script_kwargs
            )

        maybe_build_script = [build_script_name]
    else:
        maybe_build_script = []

    deps = deps + maybe_build_script

    if not has_lib:
        # HACK: create a stub target so the hub's `<crate>-<version>` alias
        # (emitted unconditionally in rs/extensions.bzl) still resolves for
        # binary-only crates. Marked as incompatible so that library use
        # fails at analysis time. The descriptive stub name & alias make the
        # error self-explanatory.
        #
        # A cleaner fix would be to make the hub skip the library alias when
        # the crate has no library, but that is non-trivial.
        stub_name = name + "_no_library_only_binary"
        native.filegroup(
            name = stub_name,
            tags = crate_tags,
            target_compatible_with = ["@platforms//:incompatible"],
            visibility = ["//visibility:public"],
        )
        native.alias(
            name = name,
            actual = stub_name,
            tags = crate_tags,
            visibility = ["//visibility:public"],
        )

    if has_lib:
        kwargs = dict(
            name = name,
            crate_name = crate_name,
            version = version,
            srcs = srcs,
            compile_data = compile_data,
            aliases = aliases,
            deps = deps,
            data = data,
            crate_features = crate_features + select(
                {_platform(k, use_legacy_rules_rust_platforms): v for k, v in conditional_crate_features.items()} |
                {"//conditions:default": []},
            ),
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
            (_rust_proc_macro if skip_deps_verification else rust_proc_macro)(**kwargs)
        else:
            (_rust_library if skip_deps_verification else rust_library)(**kwargs)

    binary_lib_dep = [name] if has_lib else []
    for binary, crate_root in binaries.items():
        rust_binary(
            name = binary + "__bin",
            compile_data = compile_data,
            aliases = aliases,
            deps = binary_lib_dep + deps,
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

def rust_crate(
        name,
        crate_name,
        purl,
        version,
        aliases,
        exec_aliases,
        deps,
        exec_deps,
        data,
        crate_features,
        triples,
        conditional_crate_features,
        exec_crate_features,
        exec_triples,
        exec_conditional_crate_features,
        crate_root,
        edition,
        rustc_flags,
        tags,
        target_compatible_with,
        exec_target_compatible_with,
        target_and_exec_compatible_with,
        links,
        build_script,
        build_script_data,
        build_deps,
        exec_build_deps,
        build_script_env,
        allow_build_script_to_detect_nonhermetic_paths,
        build_script_toolchains,
        build_script_tools,
        build_script_tags,
        is_proc_macro,
        has_lib,
        binaries,
        use_legacy_rules_rust_platforms,
        resolution_kind,
        extra_compile_data = [],
        rustc_env = {},
        skip_deps_verification = False):
    package_metadata_name = name + "_package_metadata"
    package_metadata(
        name = package_metadata_name,
        purl = purl,
        visibility = ["//visibility:public"],
    )

    crate_name = crate_name or name.replace("-", "_")
    common = dict(
        crate_name = crate_name,
        version = version,
        data = data,
        crate_root = crate_root,
        edition = edition,
        rustc_flags = rustc_flags,
        tags = tags,
        package_metadata_name = package_metadata_name,
        links = links,
        build_script = build_script,
        build_script_data = build_script_data,
        build_script_env = build_script_env,
        allow_build_script_to_detect_nonhermetic_paths = allow_build_script_to_detect_nonhermetic_paths,
        build_script_toolchains = build_script_toolchains,
        build_script_tools = build_script_tools,
        build_script_tags = build_script_tags,
        is_proc_macro = is_proc_macro,
        has_lib = has_lib,
        use_legacy_rules_rust_platforms = use_legacy_rules_rust_platforms,
        extra_compile_data = extra_compile_data,
        rustc_env = rustc_env,
        skip_deps_verification = skip_deps_verification,
    )

    if resolution_kind == "split":
        crate_variants = [
            dict(
                name = name + "_target",
                aliases = aliases,
                deps = deps,
                crate_features = crate_features,
                triples = triples,
                conditional_crate_features = conditional_crate_features,
                target_compatible_with = target_compatible_with,
                build_script_name = "_bs_target",
                build_deps = build_deps,
                binaries = binaries,
            ),
            dict(
                name = name + "_exec",
                aliases = exec_aliases,
                deps = exec_deps,
                crate_features = exec_crate_features,
                triples = exec_triples,
                conditional_crate_features = exec_conditional_crate_features,
                target_compatible_with = exec_target_compatible_with,
                build_script_name = "_bs_exec",
                build_deps = exec_build_deps,
                binaries = {},
            ),
        ]
    else:
        compatibility = {
            "target": target_compatible_with,
            "exec": exec_target_compatible_with,
            "target_and_exec": target_and_exec_compatible_with,
        }[resolution_kind]
        crate_variants = [dict(
            name = name,
            aliases = aliases,
            deps = deps,
            crate_features = crate_features,
            triples = triples,
            conditional_crate_features = conditional_crate_features,
            target_compatible_with = compatibility,
            build_script_name = "_bs",
            build_deps = build_deps,
            binaries = {} if resolution_kind == "exec" else binaries,
        )]

    for crate_variant in crate_variants:
        _rust_crate_impl(**(common | crate_variant))

    if resolution_kind != "split":
        return

    native.alias(
        name = name,
        actual = select({
            "@rules_rust//cargo/settings:use_exec_features_enabled": name + "_exec",
            "//conditions:default": name + "_target",
        }),
        tags = ["crate-name=" + crate_name] + tags,
        visibility = ["//visibility:public"],
    )
