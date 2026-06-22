load("@bazel_skylib//lib:paths.bzl", "paths")
load("@bazel_tools//tools/build_defs/repo:utils.bzl", "get_auth")
load(
    "@rules_rust//rust/private:repository_utils.bzl",
    "DEFAULT_STATIC_RUST_URL_TEMPLATES",
)
load("//rs/platforms:triples.bzl", "ALL_TARGET_TRIPLES")
load(
    "//rs/private:cargo_workspace_graph.bzl",
    "fq_crate",
    "manifest_package_dir",
    "normalize_path",
    "platform_label",
    "resolve_cargo_metadata_packages",
    "resolve_cargo_workspace_members",
    "split_lockfile_packages",
    "workspace_dep_data",
)
load("//rs/private:repository_utils.bzl", "cargo_build_file_values", "inherit_workspace_package_fields", "render_rust_crate_call")
load("//rs/private:toml2json.bzl", "run_toml2json")

_SOURCE_ROOT = "src"
_CRATES_IO_INDEX = "registry+https://github.com/rust-lang/crates.io-index"
_VENDOR_ROOT = "vendor"

_SOURCE_PACKAGE_DIRS = {
    "backtrace": "library/backtrace",
    "core_arch": "library/stdarch/crates/core_arch",
    "core_simd": "library/portable-simd/crates/core_simd",
    "libm": "library/compiler-builtins/libm",
    "std_float": "library/portable-simd/crates/std_float",
}

_EXTRA_COMPILE_DATA = {
    "compiler_builtins": [_SOURCE_PACKAGE_DIRS["libm"]],
    "core": [
        _SOURCE_PACKAGE_DIRS["core_arch"],
        _SOURCE_PACKAGE_DIRS["core_simd"],
    ],
    "std": [
        _SOURCE_PACKAGE_DIRS["backtrace"],
        _SOURCE_PACKAGE_DIRS["core_arch"],
        _SOURCE_PACKAGE_DIRS["core_simd"],
        _SOURCE_PACKAGE_DIRS["std_float"],
        "library/core",
    ],
}

def _rustc_src_tool_path(version):
    return "rustc-{}-src".format(version)

def _rustc_src_tool_suburl(version, iso_date = None):
    path = _rustc_src_tool_path(version)
    return iso_date + "/" + path if (iso_date and version in ("beta", "nightly")) else path

def _srcs_filegroup(extra_srcs = None):
    srcs = 'glob(["**/*"])'
    if extra_srcs:
        srcs = "%s + %s" % (srcs, repr(extra_srcs))

    return """\
filegroup(
    name = "srcs",
    srcs = %s,
    visibility = ["//visibility:public"],
)
""" % srcs

def _rustc_srcs_filegroup():
    return """\
filegroup(
    name = "rustc_srcs",
    srcs = [":srcs"],
    visibility = ["//visibility:public"],
)
"""

def _source_package(source_root, package_dir):
    return paths.join(source_root, package_dir) if package_dir else source_root

def _target_label(bazel_package, target):
    return "//%s:%s" % (bazel_package, target)

def _extra_compile_data(package_name, source_root):
    return [
        _target_label(_source_package(source_root, package_dir), "srcs")
        for package_dir in _EXTRA_COMPILE_DATA.get(package_name, [])
    ]

def _select_by_triple(platform_triples, by_platform):
    if not by_platform:
        return {}

    return {
        triple: sorted(by_platform.get(platform_label(triple, False), []))
        for triple in platform_triples
    }

def _resolved_select_by_triple(platform_triples, by_triple):
    if not by_triple:
        return {}

    return {
        triple: sorted(by_triple.get(triple, []))
        for triple in platform_triples
    }

def _crate_attr(
        *,
        aliases,
        build_script_deps,
        build_script_deps_select,
        crate_features,
        crate_features_select,
        deps,
        deps_select,
        extra_compile_data):
    return struct(
        allow_build_script_to_detect_nonhermetic_paths = False,
        aliases = aliases,
        build_script_data = [],
        build_script_data_select = {},
        build_script_deps = build_script_deps,
        build_script_deps_select = build_script_deps_select,
        build_script_env = {},
        build_script_env_select = {},
        build_script_tags = [],
        build_script_toolchains = [],
        build_script_tools = [],
        build_script_tools_select = {},
        crate_features = crate_features,
        crate_features_select = crate_features_select,
        crate_tags = [],
        data = [],
        deps = deps,
        deps_select = deps_select,
        extra_compile_data = extra_compile_data,
        rustc_env = {"RUSTC_BOOTSTRAP": "1"},
        rustc_flags = ["-Zforce-unstable-if-unmarked"],
        rustc_flags_select = {},
        use_legacy_rules_rust_platforms = False,
    )

def _resolved_crate_attr(feature_resolutions, platform_triples):
    return _crate_attr(
        aliases = feature_resolutions.aliases,
        build_script_deps = [],
        build_script_deps_select = _resolved_select_by_triple(platform_triples, feature_resolutions.build_deps),
        crate_features = [],
        crate_features_select = _resolved_select_by_triple(platform_triples, feature_resolutions.features_enabled),
        deps = [],
        deps_select = _resolved_select_by_triple(platform_triples, feature_resolutions.deps),
        extra_compile_data = [],
    )

def _crate_name(package_name, values):
    if values["crate_name"] != "None":
        return values["crate_name"]
    return repr(package_name.replace("-", "_"))

def _cargo_build_values(rctx, bazel_package, workspace_cargo_toml, target_name):
    cargo_toml = run_toml2json(rctx, paths.join(bazel_package, "Cargo.toml"))
    cargo_toml = inherit_workspace_package_fields(cargo_toml, workspace_cargo_toml)
    package = cargo_toml["package"]
    cargo = cargo_build_file_values(
        rctx,
        cargo_toml,
        [],
        gen_build_script = "auto",
        package_path = bazel_package,
    )
    values = cargo.values | {
        "crate_name": _crate_name(package["name"], cargo.values),
        "name": repr(target_name),
        "purl": repr("pkg:cargo/%s@%s" % (package["name"], package["version"])),
        "version": repr(package["version"]),
    }
    return struct(
        bazel_metadata = cargo.bazel_metadata,
        values = values,
    )

def _render_crate_build_file(source_root, crate_attr, values, bazel_metadata):
    return """\
load("@rules_rs//rs:rust_crate.bzl", "rust_crate", "rust_crate_target_exec_alias")
load("//{source_root}:defs.bzl", "RESOLVED_PLATFORMS")

{srcs_filegroup}{rust_crate_call}{package_metadata_bazel_additive_build_file_content}""".format(
        source_root = source_root,
        srcs_filegroup = _srcs_filegroup(),
        rust_crate_call = render_rust_crate_call(
            crate_attr,
            values,
            bazel_metadata = bazel_metadata,
            skip_deps_verification = True,
        ),
        package_metadata_bazel_additive_build_file_content = bazel_metadata.get("additive_build_file_content", ""),
    )

def _render_source_crate_build_file(rctx, source_root, bazel_package, workspace_cargo_toml, target_name, crate_attr):
    cargo = _cargo_build_values(rctx, bazel_package, workspace_cargo_toml, target_name)
    return _render_crate_build_file(source_root, crate_attr, cargo.values, cargo.bazel_metadata)

def _source_packages(source_root, lock_packages):
    packages = []
    path_source_prefix = "path+source_stdlib/"

    for package in lock_packages:
        source = package.get("source")
        package = dict(package)
        name = package["name"]
        version = package["version"]

        if source == _CRATES_IO_INDEX:
            bazel_package = _source_package(source_root, paths.join(_VENDOR_ROOT, "%s-%s" % (name, version)))
        elif source and source.startswith(path_source_prefix):
            bazel_package = _source_package(source_root, source.removeprefix(path_source_prefix))
        elif source:
            fail("Unsupported rustc-src registry source %s for %s %s" % (source, name, version))
        else:
            fail("Unknown rustc-src source %s for %s %s" % (source, name, version))

        package["bazel_package"] = bazel_package
        package["target_name"] = name
        packages.append(package)

    return packages

def _prune_rustc_src(rctx, source_root):
    for path in rctx.path(source_root).readdir():
        if path.basename not in ["library", _VENDOR_ROOT]:
            rctx.delete(path)

def _workspace_cargo_metadata(cargo_metadata):
    packages = cargo_metadata["packages"]
    workspace_member_ids = set(cargo_metadata["workspace_members"])
    return cargo_metadata | {
        "packages": [
            package
            for package in packages
            if package["id"] in workspace_member_ids
        ],
    }

def _rustc_src_repository_impl(rctx):
    tool_suburl = _rustc_src_tool_suburl(rctx.attr.version, rctx.attr.iso_date)
    urls = [url.format(tool_suburl) for url in rctx.attr.urls]

    rctx.download_and_extract(
        urls,
        output = _SOURCE_ROOT,
        sha256 = rctx.attr.sha256,
        auth = get_auth(rctx, urls),
        strip_prefix = _rustc_src_tool_path(rctx.attr.version),
    )

    root_build = [
        """\
load("@rules_rs//rs/private:source_stdlib.bzl", "source_stdlib")

package(default_visibility = ["//visibility:public"])

source_stdlib(
    name = "rust_std",
    crates = [
        "alloc",
        "compiler_builtins",
        "core",
    ] + select({
        "@rules_rs//rs/platforms/config:bpfeb-unknown-none": [],
        "@rules_rs//rs/platforms/config:bpfel-unknown-none": [],
        "//conditions:default": [
            "panic_abort",
            "std",
        ],
    }),
)
""",
    ]
    rustc_srcs = _generate_source_stdlib_build_files(rctx, _SOURCE_ROOT, root_build)
    root_build.extend([
        _srcs_filegroup(extra_srcs = rustc_srcs),
        _rustc_srcs_filegroup(),
    ])
    rctx.file(paths.join(_SOURCE_ROOT, "BUILD.bazel"), "\n".join(root_build))

    return rctx.repo_metadata(reproducible = True)

def _generate_source_stdlib_build_files(rctx, source_root, root_build):
    cargo = rctx.path(rctx.attr.cargo)
    rustc = rctx.path(rctx.attr.rustc)
    result = rctx.execute(
        [cargo, "metadata", "--manifest-path", str(rctx.path(paths.join(source_root, "library/Cargo.toml"))), "--locked", "--features", "std/backtrace", "--format-version=1", "--quiet"],
        environment = {
            "RUSTC": str(rustc),
            "RUSTC_BOOTSTRAP": "1",
        },
        working_directory = str(rctx.path(paths.join(source_root, "library"))),
    )
    if result.return_code != 0:
        fail(result.stdout + "\n" + result.stderr)

    cargo_metadata = json.decode(result.stdout)
    workspace_cargo_metadata = _workspace_cargo_metadata(cargo_metadata)
    workspace_root = normalize_path(rctx.path(source_root))
    workspace_cargo_toml = run_toml2json(rctx, paths.join(source_root, "library/Cargo.toml"))
    lock_packages = run_toml2json(rctx, paths.join(source_root, "library/Cargo.lock")).get("package", [])
    lockfile_package_info = split_lockfile_packages(
        hub_name = "source_stdlib",
        cargo_metadata = workspace_cargo_metadata,
        all_packages = lock_packages,
        workspace_cargo_toml = workspace_cargo_toml,
        repo_root = workspace_root,
        workspace_package_dir = "library",
    )
    source_packages = _source_packages(source_root, lockfile_package_info.packages)
    package_metadata_info = resolve_cargo_metadata_packages(
        source_packages,
        cargo_metadata,
        ALL_TARGET_TRIPLES,
        skip_internal_rustc_placeholder_crates = False,
    )
    resolution = resolve_cargo_workspace_members(
        rctx,
        cargo_metadata = workspace_cargo_metadata,
        packages = source_packages,
        workspace_members = lockfile_package_info.workspace_members,
        versions_by_name = package_metadata_info.versions_by_name,
        feature_resolutions_by_fq_crate = package_metadata_info.feature_resolutions_by_fq_crate,
        annotations = {
            "std": {
                "*": struct(
                    crate_features = ["backtrace"],
                    crate_features_select = {},
                ),
            },
        },
        platform_triples = ALL_TARGET_TRIPLES,
        materialize_workspace_members = True,
        dep_label_prefix = "//{}:".format(source_root),
        skip_internal_rustc_placeholder_crates = False,
    )

    dep_data_by_package = workspace_dep_data(
        cargo_metadata = workspace_cargo_metadata,
        cfg_match_cache = resolution.cfg_match_cache,
        feature_resolutions_by_fq_crate = resolution.feature_resolutions_by_fq_crate,
        platform_cfg_attrs = resolution.platform_cfg_attrs,
        platform_triples = ALL_TARGET_TRIPLES,
        repo_root = workspace_root,
        use_legacy_rules_rust_platforms = False,
        workspace_package = source_root,
    )

    crate_package_dirs = set()
    rustc_srcs = set()

    for package in workspace_cargo_metadata["packages"]:
        name = package["name"]
        version = package["version"]
        fq = fq_crate(name, version)
        package_dir = manifest_package_dir(package["manifest_path"], workspace_root)
        bazel_package = _source_package(source_root, package_dir)
        dep_data = dep_data_by_package.get(bazel_package)
        if not dep_data:
            continue
        if package_dir:
            crate_package_dirs.add(package_dir)
            rustc_srcs.add(_target_label(bazel_package, "srcs"))

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
            actual = _target_label(bazel_package, name),
            fq = fq,
            name = name,
        ))

        cargo = _cargo_build_values(rctx, bazel_package, workspace_cargo_toml, name)
        crate_attr = _crate_attr(
            aliases = dep_data["aliases"],
            build_script_deps = dep_data["build_deps"],
            build_script_deps_select = _select_by_triple(ALL_TARGET_TRIPLES, dep_data["build_deps_by_platform"]),
            crate_features = dep_data["crate_features"],
            crate_features_select = _select_by_triple(ALL_TARGET_TRIPLES, dep_data["crate_features_by_platform"]),
            deps = dep_data["deps"],
            deps_select = _select_by_triple(ALL_TARGET_TRIPLES, dep_data["deps_by_platform"]),
            extra_compile_data = _extra_compile_data(name, source_root),
        )
        rctx.file(paths.join(bazel_package, "BUILD.bazel"), _render_crate_build_file(source_root, crate_attr, cargo.values, cargo.bazel_metadata))

    for package in source_packages:
        name = package["name"]
        version = package["version"]
        fq = fq_crate(name, version)
        bazel_package = package["bazel_package"]
        target_name = package["target_name"]
        rustc_srcs.add(_target_label(bazel_package, "srcs"))
        root_build.append("""\
alias(
    name = "{fq}",
    actual = "{actual}",
)
""".format(
            actual = _target_label(bazel_package, target_name),
            fq = fq,
        ))
        rctx.file(
            paths.join(bazel_package, "BUILD.bazel"),
            _render_source_crate_build_file(
                rctx,
                source_root,
                bazel_package,
                workspace_cargo_toml,
                target_name,
                crate_attr = _resolved_crate_attr(package["feature_resolutions"], ALL_TARGET_TRIPLES),
            ),
        )

    for package_dir in sorted(_SOURCE_PACKAGE_DIRS.values()):
        bazel_package = _source_package(source_root, package_dir)
        if package_dir not in crate_package_dirs:
            rctx.file(paths.join(bazel_package, "BUILD.bazel"), _srcs_filegroup())
        rustc_srcs.add(_target_label(bazel_package, "srcs"))

    _prune_rustc_src(rctx, source_root)
    rctx.file(paths.join(source_root, "defs.bzl"), "RESOLVED_PLATFORMS = []")
    return sorted(rustc_srcs)

rustc_src_repository = repository_rule(
    implementation = _rustc_src_repository_impl,
    attrs = {
        "cargo": attr.label(
            allow_single_file = True,
            mandatory = True,
        ),
        "rustc": attr.label(
            allow_single_file = True,
            mandatory = True,
        ),
        "version": attr.string(mandatory = True),
        "iso_date": attr.string(),
        "sha256": attr.string(mandatory = True),
        "urls": attr.string_list(default = DEFAULT_STATIC_RUST_URL_TEMPLATES),
    },
)
