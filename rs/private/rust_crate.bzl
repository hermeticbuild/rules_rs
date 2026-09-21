load("@package_metadata//rules:package_metadata.bzl", "package_metadata")
load(
    "@rules_rust//rust/private:rust.bzl",
    _rust_library = "rust_library",
    _rust_proc_macro = "rust_proc_macro",
)
load("//rs:rust_binary.bzl", "rust_binary")
load("//rs:rust_library.bzl", "rust_library")
load("//rs:rust_proc_macro.bzl", "rust_proc_macro")
load(":cargo_build_script_variants.bzl", "cargo_build_script_for_targets")

def rust_crate(
        name,
        crate_name,
        purl,
        version,
        aliases,
        build_aliases,
        deps,
        link_deps,
        data,
        crate_features,
        crate_root,
        edition,
        rustc_flags,
        tags,
        target_compatible_with,
        links,
        build_script,
        build_scripts,
        build_script_data,
        build_deps,
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
        skip_deps_verification = False,
        name_suffix = ""):
    build_script_name = "_bs" + name_suffix
    package_metadata_name = name + "_package_metadata"
    if not name_suffix:
        package_metadata(
            name = package_metadata_name,
            purl = purl,
            visibility = ["//visibility:public"],
        )

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
    name += name_suffix

    if build_script:
        cargo_build_script_for_targets(
            name = build_script_name,
            build_scripts = build_scripts,
            deps = build_deps,
            aliases = build_aliases,
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

        deps = deps + [build_script_name]

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

    else:
        kwargs = dict(
            name = name,
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

    binary_lib_dep = [name] if has_lib else []
    for binary, crate_root in binaries.items():
        rust_binary(
            name = binary + "__bin",
            compile_data = compile_data,
            aliases = aliases,
            deps = binary_lib_dep + deps,
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
