load("@bazel_skylib//lib:paths.bzl", "paths")
load("@bazel_tools//tools/build_defs/repo:utils.bzl", "get_auth")
load(
    "@rules_rust//rust/private:repository_utils.bzl",
    "DEFAULT_STATIC_RUST_URL_TEMPLATES",
    "produce_tool_path",
    "produce_tool_suburl",
)
load("//rs/platforms:triples.bzl", "SOURCE_STDLIB_TARGET_TRIPLES")
load(
    "//rs/private:cargo_workspace_graph.bzl",
    "fq_crate",
    "manifest_package_dir",
    "normalize_path",
    "platform_label",
    "resolve_cargo_workspace_members",
    "workspace_dep_data",
)
load("//rs/private:repository_utils.bzl", "cargo_build_file_values", "inherit_workspace_package_fields", "render_rust_crate_call")
load("//rs/private:toml2json.bzl", "run_toml2json")

_SOURCE_ROOT = "lib/rustlib/src"

_SOURCE_PACKAGES = {
    "backtrace": "library/backtrace",
    "core_arch": "library/stdarch/crates/core_arch",
    "core_simd": "library/portable-simd/crates/core_simd",
    "libm": "library/compiler-builtins/libm",
    "std_float": "library/portable-simd/crates/std_float",
}

def _srcs_filegroup(name = "srcs", extra_srcs = None):
    srcs = 'glob(["**/*"])'
    if extra_srcs:
        srcs = "%s + %s" % (srcs, repr(extra_srcs))

    return """\
filegroup(
    name = "%s",
    srcs = %s,
    visibility = ["//visibility:public"],
)
""" % (name, srcs)

def _rustc_srcs_filegroup():
    return """\
filegroup(
    name = "rustc_srcs",
    srcs = [":srcs"],
    visibility = ["//visibility:public"],
)
"""

def _source_package(source_root, package_dir):
    if package_dir:
        return paths.join(source_root, package_dir)
    return source_root

def _target_label(source_root, package_dir, target):
    return "//%s:%s" % (_source_package(source_root, package_dir), target)

def _extra_compile_data(package_name, source_root):
    if package_name == "compiler_builtins":
        return [_target_label(source_root, _SOURCE_PACKAGES["libm"], "srcs")]
    if package_name == "core":
        return [
            _target_label(source_root, _SOURCE_PACKAGES["core_arch"], "srcs"),
            _target_label(source_root, _SOURCE_PACKAGES["core_simd"], "srcs"),
        ]
    if package_name == "std":
        return [
            _target_label(source_root, _SOURCE_PACKAGES["backtrace"], "srcs"),
            _target_label(source_root, _SOURCE_PACKAGES["core_arch"], "srcs"),
            _target_label(source_root, _SOURCE_PACKAGES["core_simd"], "srcs"),
            _target_label(source_root, _SOURCE_PACKAGES["std_float"], "srcs"),
            _target_label(source_root, "library/core", "srcs"),
        ]
    return []

def _gen_build_script(package_name):
    # These scripts are build-time helpers for rustc's bootstrap, but in this
    # generated sysroot they would be exec-configured and depend back on
    # target-only stdlib crates.
    if package_name in ["compiler_builtins", "core", "std"]:
        return "off"
    return "auto"

def _select_by_triple(platform_triples, by_platform):
    if not by_platform:
        return {}

    return {
        triple: sorted(by_platform.get(platform_label(triple, False), []))
        for triple in platform_triples
    }

def _render_resolved_platforms(platform_triples):
    return """RESOLVED_PLATFORMS = select({{
    {target_compatible_with},
    "//conditions:default": ["@platforms//:incompatible"],
}})
""".format(
        target_compatible_with = ",\n    ".join([
            '"%s": []' % platform_label(triple, False)
            for triple in platform_triples
        ]),
    )

def _rust_src_repository_impl(rctx):
    tool_suburl = produce_tool_suburl("rust-src", None, rctx.attr.version, rctx.attr.iso_date)
    urls = [url.format(tool_suburl) for url in rctx.attr.urls]

    tool_path = produce_tool_path("rust-src", rctx.attr.version)

    rctx.download_and_extract(
        urls,
        output = _SOURCE_ROOT,
        sha256 = rctx.attr.sha256,
        auth = get_auth(rctx, urls),
        strip_prefix = "{}/rust-src/lib/rustlib/src/rust".format(tool_path),
    )

    root_build = [
        "package(default_visibility = [\"//visibility:public\"])\n",
    ]
    if rctx.attr.crates:
        if not rctx.attr.cargo:
            fail("`cargo` is required when `crates` is non-empty")
        rustc_srcs = _generate_source_stdlib_build_files(rctx, _SOURCE_ROOT, root_build)
    else:
        rustc_srcs = []

    root_build.extend([
        _srcs_filegroup(extra_srcs = rustc_srcs),
        _rustc_srcs_filegroup(),
    ])

    rctx.file(paths.join(_SOURCE_ROOT, "BUILD.bazel"), "\n".join(root_build))

    return rctx.repo_metadata(reproducible = True)

def _generate_source_stdlib_build_files(rctx, source_root, root_build):
    root_build.insert(0, "load(\"@rules_rs//rs/private:source_stdlib.bzl\", \"source_stdlib\")\n")

    cargo = rctx.path(rctx.attr.cargo)
    result = rctx.execute(
        [cargo, "metadata", "--manifest-path", str(rctx.path(paths.join(source_root, "library/Cargo.toml"))), "--no-deps", "--format-version=1", "--quiet"],
        environment = {"RUSTC_BOOTSTRAP": "1"},
        working_directory = str(rctx.path(paths.join(source_root, "library"))),
    )
    if result.return_code != 0:
        fail(result.stdout + "\n" + result.stderr)

    cargo_metadata = json.decode(result.stdout)
    workspace_root = normalize_path(rctx.path(source_root))
    workspace_cargo_toml = run_toml2json(rctx, paths.join(source_root, "library/Cargo.toml"))
    workspace_member_keys = set([
        (package["name"], package["version"])
        for package in cargo_metadata["packages"]
    ])
    workspace_members = [
        dict(package)
        for package in run_toml2json(rctx, paths.join(source_root, "library/Cargo.lock")).get("package", [])
        if (package["name"], package["version"]) in workspace_member_keys
    ]
    resolution = resolve_cargo_workspace_members(
        rctx,
        hub_name = "source_stdlib",
        cargo_metadata = cargo_metadata,
        packages = [],
        workspace_members = workspace_members,
        versions_by_name = {},
        feature_resolutions_by_fq_crate = {},
        annotations = {},
        platform_triples = SOURCE_STDLIB_TARGET_TRIPLES,
        materialize_workspace_members = True,
        validate_lockfile = True,
        debug = False,
        dep_label_prefix = "//{}:".format(source_root),
        # This repo only emits rust-src workspace crates; registry crates in
        # rust-src metadata are intentionally outside this generated sysroot.
        allow_missing_resolved_deps = True,
        skip_internal_rustc_placeholder_crates = False,
    )

    dep_data_by_package = workspace_dep_data(
        cargo_metadata = cargo_metadata,
        cfg_match_cache = resolution.cfg_match_cache,
        feature_resolutions_by_fq_crate = resolution.feature_resolutions_by_fq_crate,
        platform_cfg_attrs = resolution.platform_cfg_attrs,
        platform_triples = SOURCE_STDLIB_TARGET_TRIPLES,
        repo_root = workspace_root,
        use_legacy_rules_rust_platforms = False,
        workspace_package = source_root,
    )

    platform_triples = sorted(SOURCE_STDLIB_TARGET_TRIPLES)
    rustc_srcs = set()
    crate_package_dirs = set()

    for package in cargo_metadata["packages"]:
        name = package["name"]
        version = package["version"]
        fq = fq_crate(name, version)
        package_dir = manifest_package_dir(package["manifest_path"], workspace_root)
        bazel_package = _source_package(source_root, package_dir)
        dep_data = dep_data_by_package[bazel_package]
        if package_dir:
            crate_package_dirs.add(package_dir)
            rustc_srcs.add(_target_label(source_root, package_dir, "srcs"))

        root_build.append("""\
alias(
    name = "{fq}",
    actual = "{actual}",
)

alias(
    name = "{name}",
    actual = "{fq}",
)
""".format(
            actual = _target_label(source_root, package_dir, name),
            fq = fq,
            name = name,
        ))

        cargo_toml = run_toml2json(rctx, paths.join(bazel_package, "Cargo.toml"))
        cargo_toml = inherit_workspace_package_fields(cargo_toml, workspace_cargo_toml)
        cargo = cargo_build_file_values(
            rctx,
            cargo_toml,
            [],
            gen_build_script = _gen_build_script(name),
            package_path = bazel_package,
        )
        values = dict(cargo.values)
        values.update({
            "name": repr(name),
            "purl": repr("pkg:cargo/%s@%s" % (name, version)),
            "version": repr(version),
        })
        crate_attr = struct(
            aliases = dep_data["aliases"],
            build_script_data = [],
            build_script_data_select = {},
            build_script_deps = dep_data["build_deps"],
            build_script_deps_select = _select_by_triple(platform_triples, dep_data["build_deps_by_platform"]),
            build_script_env = {},
            build_script_env_select = {},
            build_script_tags = [],
            build_script_toolchains = [],
            build_script_tools = [],
            build_script_tools_select = {},
            cargo_toml_env = False,
            crate_features = dep_data["crate_features"],
            crate_features_select = _select_by_triple(platform_triples, dep_data["crate_features_by_platform"]),
            crate_tags = [],
            data = [],
            deps = dep_data["deps"],
            deps_select = _select_by_triple(platform_triples, dep_data["deps_by_platform"]),
            extra_compile_data = _extra_compile_data(name, source_root),
            rustc_env = {"RUSTC_BOOTSTRAP": "1"},
            rustc_flags = ["-Zforce-unstable-if-unmarked"],
            rustc_flags_select = {},
            use_legacy_rules_rust_platforms = False,
        )
        rctx.file(paths.join(bazel_package, "BUILD.bazel"), """\
load("@rules_rs//rs:rust_crate.bzl", "rust_crate")
load("//{source_root}:defs.bzl", "RESOLVED_PLATFORMS")

{srcs_filegroup}{rust_crate_call}{package_metadata_bazel_additive_build_file_content}""".format(
            source_root = source_root,
            srcs_filegroup = _srcs_filegroup(),
            rust_crate_call = render_rust_crate_call(
                crate_attr,
                values,
                bazel_metadata = cargo.bazel_metadata,
                skip_deps_verification = True,
            ),
            package_metadata_bazel_additive_build_file_content = cargo.bazel_metadata.get("additive_build_file_content", ""),
        ))

    for package_dir in sorted(_SOURCE_PACKAGES.values()):
        if package_dir not in crate_package_dirs:
            rctx.file(paths.join(_source_package(source_root, package_dir), "BUILD.bazel"), _srcs_filegroup())
        rustc_srcs.add(_target_label(source_root, package_dir, "srcs"))

    root_build.append("""\
source_stdlib(
    name = "rust_std",
    crates = {crates},
)
""".format(crates = repr(sorted(rctx.attr.crates))))

    rctx.file(paths.join(source_root, "defs.bzl"), _render_resolved_platforms(SOURCE_STDLIB_TARGET_TRIPLES))
    return sorted(rustc_srcs)

rust_src_repository = repository_rule(
    implementation = _rust_src_repository_impl,
    attrs = {
        "cargo": attr.label(
            allow_single_file = True,
        ),
        "crates": attr.string_list(),
        "version": attr.string(mandatory = True),
        "iso_date": attr.string(),
        "sha256": attr.string(mandatory = True),
        "urls": attr.string_list(default = DEFAULT_STATIC_RUST_URL_TEMPLATES),
    },
)
