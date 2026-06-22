load(":select_utils.bzl", "compute_select")
load(":semver.bzl", "parse_full_version")

# Bazel 8 does not define attr.label_list_dict.
_label_list_dict = getattr(attr, "label_list_dict", attr.string_list_dict)

def _platform(triple, use_legacy_rules_rust_platforms):
    if use_legacy_rules_rust_platforms:
        return "@rules_rust//rust/platform:" + triple.replace("-musl", "-gnu").replace("-gnullvm", "-msvc")
    return "@rules_rs//rs/platforms/config:" + triple

def _format_branches(branches):
    return """select({
        %s
    })""" % (
        ",\n        ".join(['"%s": %s' % branch for branch in branches])
    )

def render_select(non_platform_items, platform_items, use_legacy_rules_rust_platforms):
    non_platform_items = [str(item) for item in non_platform_items]
    platform_items = {
        platform: [str(item) for item in items]
        for platform, items in platform_items.items()
    }
    common_items, branches = compute_select(non_platform_items, platform_items)
    common_items = list(common_items)

    if not branches:
        return common_items, ""

    branches = [(_platform(k, use_legacy_rules_rust_platforms), repr(v)) for k, v in branches.items()]
    branches.append(("//conditions:default", "[],"))

    return common_items, _format_branches(branches)

def render_select_build_script_env(platform_items, use_legacy_rules_rust_platforms):
    branches = [
        (_platform(triple, use_legacy_rules_rust_platforms), items)
        for triple, items in platform_items.items()
    ]

    if not branches:
        return ""

    branches.append(("//conditions:default", "{},"))

    return _format_branches(branches)

def _exclude_deps_from_features(features):
    return [f for f in features if not f.startswith("dep:")]

_INHERITABLE_PACKAGE_FIELDS = [
    "version",
    "edition",
    "description",
    "homepage",
    "repository",
    "license",
    # TODO(zbarsky): Do we need to fixup the path for readme and license_file?
    "license_file",
    "rust_version",
    "readme",
]

def inherit_workspace_package_fields(cargo_toml, workspace_cargo_toml):
    workspace_package = workspace_cargo_toml.get("workspace", {}).get("package")
    if not workspace_package:
        return cargo_toml

    crate_package = cargo_toml["package"]
    for field in _INHERITABLE_PACKAGE_FIELDS:
        value = crate_package.get(field)
        if type(value) == "dict" and value.get("workspace") == True:
            crate_package[field] = workspace_package.get(field)

    return cargo_toml

def cargo_build_file_values(rctx, cargo_toml, gen_binaries, package_path = "", gen_build_script = None):
    package_dir = rctx.path(package_path or ".")
    package = cargo_toml["package"]
    if gen_build_script == None:
        gen_build_script = rctx.attr.gen_build_script

    name = package["name"]
    version = package["version"]
    parsed_version = parse_full_version(version)

    readme = package.get("readme", "")
    if (not readme or readme == True) and package_dir.get_child("README.md").exists:
        readme = "README.md"

    cargo_toml_env_vars = {
        "CARGO_PKG_VERSION": version,
        "CARGO_PKG_VERSION_MAJOR": str(parsed_version[0]),
        "CARGO_PKG_VERSION_MINOR": str(parsed_version[1]),
        "CARGO_PKG_VERSION_PATCH": str(parsed_version[2]),
        "CARGO_PKG_VERSION_PRE": parsed_version[3],
        "CARGO_PKG_NAME": name,
        "CARGO_PKG_AUTHORS": ":".join(package.get("authors", [])),
        "CARGO_PKG_DESCRIPTION": package.get("description", "").replace("\n", "\\"),
        "CARGO_PKG_HOMEPAGE": package.get("homepage", ""),
        "CARGO_PKG_REPOSITORY": package.get("repository", ""),
        "CARGO_PKG_LICENSE": package.get("license", ""),
        "CARGO_PKG_LICENSE_FILE": package.get("license_file", ""),
        "CARGO_PKG_RUST_VERSION": package.get("rust-version", ""),
        "CARGO_PKG_README": readme,
    }

    rctx.file(
        package_dir.get_child("cargo_toml_env_vars.env"),
        "\n".join(["%s=%s" % kv for kv in cargo_toml_env_vars.items()]),
    )

    bazel_metadata = package.get("metadata", {}).get("bazel", {})

    if gen_build_script == "off" or bazel_metadata.get("gen_build_script") == False:
        build_script = None
    else:
        # What does `gen_build_script="on"` do? Fail the build if we don't detect one?
        build_script = package.get("build")
        if build_script:
            build_script = build_script.removeprefix("./")
        elif package_dir.get_child("build.rs").exists:
            build_script = "build.rs"

    lib = cargo_toml.get("lib", {})
    is_proc_macro = lib.get("proc-macro") or lib.get("proc_macro") or False
    crate_root = (lib.get("path") or "src/lib.rs").removeprefix("./")
    has_lib = "lib" in cargo_toml or package_dir.get_child(crate_root).exists

    edition = package.get("edition", "2015")
    crate_name = lib.get("name")
    links = package.get("links")

    toml_bins = cargo_toml.get("bin", []) + [{"name": package["name"]}]

    binaries = {}
    for bin in toml_bins:
        bin_name = bin["name"]
        if bin_name not in gen_binaries or bin_name in binaries:
            continue

        bin_path = bin.get("path")
        if bin_path:
            binaries[bin_name] = bin_path.removeprefix("./")
            continue

        for candidate in ["src/bin/%s.rs" % bin_name, "src/bin/%s/main.rs" % bin_name, "src/main.rs"]:
            if package_dir.get_child(candidate).exists:
                binaries[bin_name] = candidate
                break

    return struct(
        bazel_metadata = bazel_metadata,
        values = {
            "binaries": repr(binaries),
            "build_script": repr(build_script),
            "crate_name": repr(crate_name),
            "crate_root": repr(crate_root),
            "edition": repr(edition),
            "has_lib": repr(has_lib),
            "is_proc_macro": repr(is_proc_macro),
            "links": repr(links),
        },
    )

_RUST_CRATE_MACRO_CALL = """{indent}rust_crate(
{indent}    name = {name}{name_suffix},
{indent}    crate_name = {crate_name} or {name}.replace("-", "_"),
{indent}    purl = {purl},
{indent}    version = {version},
{indent}    aliases = {{
{indent}        {aliases}
{indent}    }},
{indent}    deps = [
{indent}        {deps}
{indent}    ]{extra_deps}{conditional_deps},
{indent}    data = [
{indent}        {data}
{indent}    ],
{extra_compile_data_attr}{indent}    crate_features = {crate_features},
{indent}    triples = {triples},
{indent}    conditional_crate_features = {conditional_crate_features},
{indent}    crate_root = {crate_root},
{indent}    edition = {edition},
{rustc_env_attr}{indent}    rustc_flags = {rustc_flags}{conditional_rustc_flags},
{indent}    tags = {tags},
{indent}    target_compatible_with = {target_compatible_with},
{indent}    links = {links},
{indent}    build_script = {build_script},
{indent}    build_script_data = {build_script_data}{conditional_build_script_data},
{indent}    build_deps = [
{indent}        {build_deps}
{indent}    ]{conditional_build_deps},
{indent}    build_script_env = {build_script_env}{conditional_build_script_env},
{indent}    allow_build_script_to_detect_nonhermetic_paths = {allow_build_script_to_detect_nonhermetic_paths},
{indent}    build_script_toolchains = {build_script_toolchains},
{indent}    build_script_tools = {build_script_tools}{conditional_build_script_tools},
{indent}    build_script_tags = {build_script_tags},
{indent}    is_proc_macro = {is_proc_macro},
{indent}    has_lib = {has_lib},
{indent}    binaries = {binaries},
{indent}    use_legacy_rules_rust_platforms = {use_legacy_rules_rust_platforms},
{indent}    build_script_name = {build_script_name},
{skip_deps_verification_attr}{indent})
"""

def _render_rust_crate_call(
        attr,
        values,
        aliases,
        crate_features_select,
        deps_select,
        build_deps_select,
        target_compatible_with,
        name_suffix,
        binaries,
        bazel_metadata,
        extra_deps,
        indent,
        skip_deps_verification):
    # We keep conditional_crate_features unrendered here because it must be treated specially for build scripts.
    # See `rust_crate.bzl` for details.
    crate_features, conditional_crate_features = compute_select(
        _exclude_deps_from_features(attr.crate_features),
        {platform: _exclude_deps_from_features(features) for platform, features in crate_features_select.items()},
    )
    use_legacy_rules_rust_platforms = attr.use_legacy_rules_rust_platforms
    build_deps, conditional_build_deps = render_select(attr.build_script_deps, build_deps_select, use_legacy_rules_rust_platforms)
    build_script_data, conditional_build_script_data = render_select(attr.build_script_data, attr.build_script_data_select, use_legacy_rules_rust_platforms)
    build_script_tools, conditional_build_script_tools = render_select(attr.build_script_tools, attr.build_script_tools_select, use_legacy_rules_rust_platforms)
    rustc_flags, conditional_rustc_flags = render_select(attr.rustc_flags, attr.rustc_flags_select, use_legacy_rules_rust_platforms)
    deps, conditional_deps = render_select(attr.deps + bazel_metadata.get("deps", []), deps_select, use_legacy_rules_rust_platforms)

    conditional_build_script_env = render_select_build_script_env(attr.build_script_env_select, use_legacy_rules_rust_platforms)

    list_indent = ",\n%s        " % indent
    extra_deps = " + " + extra_deps if extra_deps else ""
    extra_compile_data = getattr(attr, "extra_compile_data", [])
    extra_compile_data_attr = ""
    if extra_compile_data:
        extra_compile_data_attr = """{indent}    extra_compile_data = [
{indent}        {extra_compile_data}
{indent}    ],
""".format(
            indent = indent,
            extra_compile_data = list_indent.join(['"%s"' % d for d in extra_compile_data]),
        )
    rustc_env = getattr(attr, "rustc_env", {})
    rustc_env_attr = "%s    rustc_env = %s,\n" % (indent, repr(rustc_env)) if rustc_env else ""
    skip_deps_verification_attr = "%s    skip_deps_verification = True,\n" % indent if skip_deps_verification else ""

    return _RUST_CRATE_MACRO_CALL.format(
        indent = indent,
        name = values["name"],
        name_suffix = " + " + repr(name_suffix) if name_suffix else "",
        crate_name = values["crate_name"],
        purl = values["purl"],
        version = values["version"],
        aliases = list_indent.join(['"%s": "%s"' % kv for kv in aliases.items()]),
        deps = list_indent.join(['"%s"' % d for d in sorted(deps)]),
        extra_deps = extra_deps,
        conditional_deps = " + " + conditional_deps if conditional_deps else "",
        data = list_indent.join(['"%s"' % str(d) for d in attr.data]),
        extra_compile_data_attr = extra_compile_data_attr,
        crate_features = repr(sorted(crate_features)),
        triples = repr(crate_features_select.keys()),
        conditional_crate_features = repr(conditional_crate_features),
        crate_root = values["crate_root"],
        edition = values["edition"],
        rustc_env_attr = rustc_env_attr,
        rustc_flags = repr(rustc_flags),
        conditional_rustc_flags = " + " + conditional_rustc_flags if conditional_rustc_flags else "",
        tags = repr(attr.crate_tags),
        target_compatible_with = target_compatible_with,
        links = values["links"],
        build_script = values["build_script"],
        build_script_data = repr(build_script_data),
        conditional_build_script_data = " + " + conditional_build_script_data if conditional_build_script_data else "",
        build_deps = list_indent.join(['"%s"' % d for d in sorted(build_deps)]),
        conditional_build_deps = " + " + conditional_build_deps if conditional_build_deps else "",
        build_script_env = repr(attr.build_script_env),
        conditional_build_script_env = " | " + conditional_build_script_env if conditional_build_script_env else "",
        allow_build_script_to_detect_nonhermetic_paths = repr(attr.allow_build_script_to_detect_nonhermetic_paths),
        build_script_toolchains = repr([str(t) for t in attr.build_script_toolchains]),
        build_script_tools = repr(build_script_tools),
        conditional_build_script_tools = " + " + conditional_build_script_tools if conditional_build_script_tools else "",
        build_script_tags = repr(attr.build_script_tags),
        is_proc_macro = values["is_proc_macro"],
        has_lib = values["has_lib"],
        binaries = binaries,
        use_legacy_rules_rust_platforms = use_legacy_rules_rust_platforms,
        build_script_name = repr("_bs" + name_suffix),
        skip_deps_verification_attr = skip_deps_verification_attr,
    )

def _merge_target_and_exec(target_values, exec_values):
    return target_values | exec_values if all([
        key not in target_values or target_values[key] == exec_value
        for key, exec_value in exec_values.items()
    ]) else None

def render_rust_crate_call(attr, values, bazel_metadata = {}, extra_deps = "", indent = "", skip_deps_verification = False):
    exec_active = getattr(attr, "exec_active", False)
    aliases = attr.aliases
    crate_features_select = attr.crate_features_select
    deps_select = attr.deps_select
    build_deps_select = attr.build_script_deps_select
    target_compatible_with = "RESOLVED_PLATFORMS"
    binaries = values["binaries"]

    if not getattr(attr, "target_active", True) and exec_active:
        aliases = attr.exec_aliases
        crate_features_select = attr.exec_crate_features_select
        deps_select = attr.exec_deps_select
        build_deps_select = attr.exec_build_script_deps_select
        target_compatible_with = "None"
        binaries = "{}"
    elif exec_active:
        merged_crate_features_select = _merge_target_and_exec(crate_features_select, attr.exec_crate_features_select)
        merged_deps_select = _merge_target_and_exec(deps_select, attr.exec_deps_select)
        merged_build_deps_select = _merge_target_and_exec(build_deps_select, attr.exec_build_script_deps_select)
        merged_aliases = _merge_target_and_exec(aliases, attr.exec_aliases)
        if None in [merged_crate_features_select, merged_deps_select, merged_build_deps_select, merged_aliases]:
            target_call = _render_rust_crate_call(
                attr,
                values,
                aliases,
                crate_features_select,
                deps_select,
                build_deps_select,
                "RESOLVED_PLATFORMS",
                "_target",
                binaries,
                bazel_metadata,
                extra_deps,
                indent,
                skip_deps_verification,
            )
            exec_call = _render_rust_crate_call(
                attr,
                values,
                attr.exec_aliases,
                attr.exec_crate_features_select,
                attr.exec_deps_select,
                attr.exec_build_script_deps_select,
                "None",
                "_exec",
                "{}",
                bazel_metadata,
                extra_deps,
                indent,
                skip_deps_verification,
            )
            alias_call = """{indent}rust_crate_target_exec_alias(
{indent}    name = {name},
{indent}    crate_name = {crate_name},
{indent}    tags = {tags},
{indent})
""".format(
                crate_name = values["crate_name"],
                indent = indent,
                name = values["name"],
                tags = repr(attr.crate_tags),
            )
            return target_call + "\n" + exec_call + "\n" + alias_call

        aliases = merged_aliases
        crate_features_select = merged_crate_features_select
        deps_select = merged_deps_select
        build_deps_select = merged_build_deps_select
        target_compatible_with = "None"

    return _render_rust_crate_call(
        attr,
        values,
        aliases,
        crate_features_select,
        deps_select,
        build_deps_select,
        target_compatible_with,
        "",
        binaries,
        bazel_metadata,
        extra_deps,
        indent,
        skip_deps_verification,
    )

def render_build_file_content(rctx, attr, values, bazel_metadata = {}):
    additive_build_file_content = ""
    if attr.additive_build_file:
        additive_build_file_content += rctx.read(attr.additive_build_file)
    additive_build_file_content += attr.additive_build_file_content
    additive_build_file_content += bazel_metadata.get("additive_build_file_content", "")

    return """\
load("@rules_rs//rs:rust_crate.bzl", "rust_crate", "rust_crate_target_exec_alias")
load("@rules_rs//rs:rust_binary.bzl", "rust_binary")
load("@{hub_name}//:defs.bzl", "RESOLVED_PLATFORMS")

{rust_crate_call}""".format(
        hub_name = attr.hub_name,
        rust_crate_call = render_rust_crate_call(attr, values, bazel_metadata = bazel_metadata),
    ) + additive_build_file_content

rust_crate_attrs = {
    "hub_name": attr.string(),
    "gen_build_script": attr.string(),
    "build_script_deps": attr.label_list(),
    "build_script_deps_select": _label_list_dict(),
    "exec_build_script_deps_select": _label_list_dict(),
    "build_script_data": attr.label_list(),
    "build_script_data_select": _label_list_dict(),
    "build_script_env": attr.string_dict(),
    "build_script_env_select": attr.string_dict(),
    "allow_build_script_to_detect_nonhermetic_paths": attr.bool(default = False),
    "build_script_toolchains": attr.label_list(),
    "build_script_tools": attr.label_list(),
    "build_script_tools_select": _label_list_dict(),
    "build_script_tags": attr.string_list(),
    "rustc_flags": attr.string_list(),
    "rustc_flags_select": attr.string_list_dict(),
    "crate_tags": attr.string_list(),
    "data": attr.label_list(),
    "deps": attr.label_list(),
    "deps_select": _label_list_dict(),
    "exec_deps_select": _label_list_dict(),
    "aliases": attr.string_dict(),
    "exec_aliases": attr.string_dict(),
    "crate_features": attr.string_list(),
    "crate_features_select": attr.string_list_dict(),
    "exec_crate_features_select": attr.string_list_dict(),
    "target_active": attr.bool(),
    "exec_active": attr.bool(),
    "use_legacy_rules_rust_platforms": attr.bool(),
}

common_attrs = rust_crate_attrs | {
    "additive_build_file": attr.label(),
    "additive_build_file_content": attr.string(),
    "gen_binaries": attr.string_list(),
} | {
    "strip_prefix": attr.string(
        default = "",
        doc = "A directory prefix to strip from the extracted files.",
    ),
    "patches": attr.label_list(
        default = [],
        doc =
            "A list of files that are to be applied as patches after " +
            "extracting the archive. By default, it uses the Bazel-native patch implementation " +
            "which doesn't support fuzz match and binary patch, but Bazel will fall back to use " +
            "patch command line tool if `patch_tool` attribute is specified or there are " +
            "arguments other than `-p` in `patch_args` attribute.",
    ),
    "patch_tool": attr.string(
        default = "",
        doc = "The patch(1) utility to use. If this is specified, Bazel will use the specified " +
              "patch tool instead of the Bazel-native patch implementation.",
    ),
    "patch_args": attr.string_list(
        default = [],
        doc =
            "The arguments given to the patch tool. Defaults to -p0 (see the `patch_strip` " +
            "attribute), however -p1 will usually be needed for patches generated by " +
            "git. If multiple -p arguments are specified, the last one will take effect." +
            "If arguments other than -p are specified, Bazel will fall back to use patch " +
            "command line tool instead of the Bazel-native patch implementation. When falling " +
            "back to patch command line tool and patch_tool attribute is not specified, " +
            "`patch` will be used.",
    ),
    "patch_strip": attr.int(
        default = 0,
        doc = "When set to `N`, this is equivalent to inserting `-pN` to the beginning of `patch_args`.",
    ),
    "patch_cmds": attr.string_list(
        default = [],
        doc = "Sequence of Bash commands to be applied on Linux/Macos after patches are applied.",
    ),
    "patch_cmds_win": attr.string_list(
        default = [],
        doc = "Sequence of Powershell commands to be applied on Windows after patches are " +
              "applied. If this attribute is not set, patch_cmds will be executed on Windows, " +
              "which requires Bash binary to exist.",
    ),
}
