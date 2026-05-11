load("@bazel_skylib//lib:paths.bzl", "paths")
load("@bazel_tools//tools/build_defs/repo:utils.bzl", "get_auth")
load(
    "@rules_rust//rust/private:repository_utils.bzl",
    "DEFAULT_STATIC_RUST_URL_TEMPLATES",
    "produce_tool_path",
    "produce_tool_suburl",
)
load("//rs/platforms:triples.bzl", "SUPPORTED_TIER_3_TRIPLES")
load(
    "//rs/private:cargo_workspace_graph.bzl",
    "cargo_toml_fact",
    "fq_crate",
    "manifest_package_dir",
    "normalize_path",
    "platform_label",
    "resolve_cargo_workspace_members",
    "resolve_package_facts",
    "split_lockfile_packages",
    "workspace_dep_data",
)
load("//rs/private:repository_utils.bzl", "cargo_build_file_values", "inherit_workspace_package_fields", "render_rust_crate_call")
load("//rs/private:toml2json.bzl", "run_toml2json")

_SOURCE_ROOT = "lib/rustlib/src"
_CRATES_IO_INDEX = "registry+https://github.com/rust-lang/crates.io-index"
_CRATES_IO_DOWNLOAD_URL = "https://crates.io/api/v1/crates/{crate}/{version}/download"
_VENDOR_ROOT = "vendor"

_SOURCE_PACKAGES = {
    "backtrace": "library/backtrace",
    "core_arch": "library/stdarch/crates/core_arch",
    "core_simd": "library/portable-simd/crates/core_simd",
    "libm": "library/compiler-builtins/libm",
    "std_float": "library/portable-simd/crates/std_float",
}

_EXTRA_COMPILE_DATA = {
    "compiler_builtins": [_SOURCE_PACKAGES["libm"]],
    "core": [
        _SOURCE_PACKAGES["core_arch"],
        _SOURCE_PACKAGES["core_simd"],
    ],
    "std": [
        _SOURCE_PACKAGES["backtrace"],
        _SOURCE_PACKAGES["core_arch"],
        _SOURCE_PACKAGES["core_simd"],
        _SOURCE_PACKAGES["std_float"],
        "library/core",
    ],
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

def _source_package(source_root, package_dir):
    if package_dir:
        return paths.join(source_root, package_dir)
    return source_root

def _target_label(source_root, package_dir, target):
    return "//%s:%s" % (_source_package(source_root, package_dir), target)

def _registry_package_dir(package):
    return paths.join(_VENDOR_ROOT, "%s-%s" % (package["name"], package["version"]))

def _extra_compile_data(package_name, source_root):
    return [
        _target_label(source_root, package_dir, "srcs")
        for package_dir in _EXTRA_COMPILE_DATA.get(package_name, [])
    ]

def _source_stdlib_annotations():
    return {
        "std": {
            "0.0.0": struct(
                crate_features = ["backtrace"],
                crate_features_select = {},
            ),
        },
    }

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
load("@rules_rs//rs:rust_crate.bzl", "rust_crate")
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

def _render_source_crate_build_file(rctx, source_root, package_dir, workspace_cargo_toml, target_name, crate_attr):
    bazel_package = _source_package(source_root, package_dir)
    cargo = _cargo_build_values(rctx, bazel_package, workspace_cargo_toml, target_name)
    return _render_crate_build_file(source_root, crate_attr, cargo.values, cargo.bazel_metadata)

def _source_package_fact(rctx, source_root, package, package_dir, workspace_cargo_toml = None, target_name = None):
    package = dict(package)
    name = package["name"]
    version = package["version"]
    cargo_toml = run_toml2json(rctx, paths.join(source_root, package_dir, "Cargo.toml"))
    if workspace_cargo_toml:
        cargo_toml = inherit_workspace_package_fields(cargo_toml, workspace_cargo_toml)
    manifest_package = cargo_toml["package"]
    if manifest_package["name"] != name or manifest_package["version"] != version:
        fail("Cargo.lock has %s %s but %s/Cargo.toml has %s %s" % (
            name,
            version,
            package_dir,
            manifest_package["name"],
            manifest_package["version"],
        ))
    fact = cargo_toml_fact(cargo_toml, workspace_cargo_toml)
    package["package_dir"] = package_dir
    package["target_name"] = target_name or name
    return package, fact

def _materialize_source_packages(rctx, source_root, lock_packages, workspace_cargo_toml):
    packages = []
    facts_by_fq_crate = {}

    for package in lock_packages:
        source = package.get("source")
        package = dict(package)
        name = package["name"]
        version = package["version"]

        if source == _CRATES_IO_INDEX:
            package_dir = _registry_package_dir(package)
            target_name = name
            package_workspace_cargo_toml = None
            rctx.download_and_extract(
                _CRATES_IO_DOWNLOAD_URL.format(crate = name, version = version),
                output = paths.join(source_root, package_dir),
                sha256 = package["checksum"],
                strip_prefix = "%s-%s" % (name, version),
                type = "tar.gz",
            )
        elif source and source.startswith("path+"):
            package_dir = normalize_path(package["local_path"]).removeprefix(normalize_path(rctx.path(source_root)) + "/")
            target_name = paths.basename(package_dir)
            package_workspace_cargo_toml = workspace_cargo_toml
        elif source:
            fail("Unsupported rust-src registry source %s for %s %s" % (source, name, version))
        else:
            fail("Unknown rust-src source %s for %s %s" % (source, name, version))

        package, fact = _source_package_fact(
            rctx,
            source_root,
            package,
            package_dir,
            workspace_cargo_toml = package_workspace_cargo_toml,
            target_name = target_name,
        )
        packages.append(package)
        facts_by_fq_crate[fq_crate(name, version)] = fact

    return struct(
        facts_by_fq_crate = facts_by_fq_crate,
        packages = packages,
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
        "load(\"@rules_rs//rs/private:source_stdlib.bzl\", \"source_stdlib\")\n",
        "package(default_visibility = [\"//visibility:public\"])\n",
    ]
    rustc_srcs = _generate_source_stdlib_build_files(rctx, _SOURCE_ROOT, root_build)

    root_build.extend([
        _srcs_filegroup(extra_srcs = rustc_srcs),
        """\
filegroup(
    name = "rustc_srcs",
    srcs = [":srcs"],
    visibility = ["//visibility:public"],
)
""",
    ])

    rctx.file(paths.join(_SOURCE_ROOT, "BUILD.bazel"), "\n".join(root_build))

    return rctx.repo_metadata(reproducible = True)

def _generate_source_stdlib_build_files(rctx, source_root, root_build):
    platform_triples = sorted(SUPPORTED_TIER_3_TRIPLES)

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
    lock_packages = run_toml2json(rctx, paths.join(source_root, "library/Cargo.lock")).get("package", [])
    lockfile_package_info = split_lockfile_packages(
        hub_name = "source_stdlib",
        cargo_metadata = cargo_metadata,
        all_packages = lock_packages,
        workspace_cargo_toml = workspace_cargo_toml,
        repo_root = workspace_root,
        workspace_package_dir = "library",
    )
    source_packages = _materialize_source_packages(
        rctx,
        source_root,
        lockfile_package_info.packages,
        workspace_cargo_toml,
    )
    package_fact_info = resolve_package_facts(
        source_packages.packages,
        source_packages.facts_by_fq_crate,
        platform_triples,
        skip_internal_rustc_placeholder_crates = False,
    )
    resolution = resolve_cargo_workspace_members(
        rctx,
        hub_name = "source_stdlib",
        cargo_metadata = cargo_metadata,
        packages = source_packages.packages,
        workspace_members = lockfile_package_info.workspace_members,
        versions_by_name = package_fact_info.versions_by_name,
        feature_resolutions_by_fq_crate = package_fact_info.feature_resolutions_by_fq_crate,
        annotations = _source_stdlib_annotations(),
        platform_triples = platform_triples,
        materialize_workspace_members = True,
        dep_label_prefix = "//{}:".format(source_root),
        skip_internal_rustc_placeholder_crates = False,
    )

    dep_data_by_package = workspace_dep_data(
        cargo_metadata = cargo_metadata,
        cfg_match_cache = resolution.cfg_match_cache,
        feature_resolutions_by_fq_crate = resolution.feature_resolutions_by_fq_crate,
        platform_cfg_attrs = resolution.platform_cfg_attrs,
        platform_triples = platform_triples,
        repo_root = workspace_root,
        use_legacy_rules_rust_platforms = False,
        workspace_package = source_root,
    )

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

        cargo = _cargo_build_values(rctx, bazel_package, workspace_cargo_toml, name)
        crate_attr = _crate_attr(
            aliases = dep_data["aliases"],
            build_script_deps = dep_data["build_deps"],
            build_script_deps_select = _select_by_triple(platform_triples, dep_data["build_deps_by_platform"]),
            crate_features = dep_data["crate_features"],
            crate_features_select = _select_by_triple(platform_triples, dep_data["crate_features_by_platform"]),
            deps = dep_data["deps"],
            deps_select = _select_by_triple(platform_triples, dep_data["deps_by_platform"]),
            extra_compile_data = _extra_compile_data(name, source_root),
        )
        rctx.file(paths.join(bazel_package, "BUILD.bazel"), _render_crate_build_file(source_root, crate_attr, cargo.values, cargo.bazel_metadata))

    for package in source_packages.packages:
        name = package["name"]
        version = package["version"]
        fq = fq_crate(name, version)
        package_dir = package["package_dir"]
        target_name = package["target_name"]
        rustc_srcs.add(_target_label(source_root, package_dir, "srcs"))
        root_build.append("""\
alias(
    name = "{fq}",
    actual = "{actual}",
)
""".format(
            actual = _target_label(source_root, package_dir, target_name),
            fq = fq,
        ))
        rctx.file(
            paths.join(_source_package(source_root, package_dir), "BUILD.bazel"),
            _render_source_crate_build_file(
                rctx,
                source_root,
                package_dir,
                workspace_cargo_toml,
                target_name,
                crate_attr = _resolved_crate_attr(package["feature_resolutions"], platform_triples),
            ),
        )

    for package_dir in sorted(_SOURCE_PACKAGES.values()):
        if package_dir not in crate_package_dirs:
            rctx.file(paths.join(_source_package(source_root, package_dir), "BUILD.bazel"), _srcs_filegroup())
        rustc_srcs.add(_target_label(source_root, package_dir, "srcs"))

    root_build.append("""\
source_stdlib(
    name = "rust_std",
    crates = [
        "alloc",
        "compiler_builtins",
        "core",
        "panic_abort",
        "std",
    ],
)
""")

    rctx.file(paths.join(source_root, "defs.bzl"), "RESOLVED_PLATFORMS = []")
    return sorted(rustc_srcs)

rust_src_repository = repository_rule(
    implementation = _rust_src_repository_impl,
    attrs = {
        "cargo": attr.label(
            allow_single_file = True,
            mandatory = True,
        ),
        "version": attr.string(mandatory = True),
        "iso_date": attr.string(),
        "sha256": attr.string(mandatory = True),
        "urls": attr.string_list(default = DEFAULT_STATIC_RUST_URL_TEMPLATES),
    },
)
