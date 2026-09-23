load(":cargo_toml_utils.bzl", "cargo_toml_is_proc_macro")
load(":select_utils.bzl", "compute_select", "platform_label")
load(":semver.bzl", "parse_full_version")

# Bazel 8 does not define attr.label_list_dict.
_label_list_dict = getattr(attr, "label_list_dict", attr.string_list_dict)

def _format_branches(branches):
    return """select({
        %s
    })""" % ",\n        ".join(branches)

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

    branches = {platform_label(triple, use_legacy_rules_rust_platforms): branches[triple] for triple in branches}
    branches = ['"%s": %s' % (platform, repr(branches[platform])) for platform in branches]
    branches.append('"//conditions:default": []')

    return common_items, _format_branches(branches)

def render_select_build_script_env(platform_items, use_legacy_rules_rust_platforms):
    branches = [
        '"%s": %s' % (platform_label(triple, use_legacy_rules_rust_platforms), platform_items[triple])
        for triple in platform_items
    ]

    if not branches:
        return ""

    branches.append('"//conditions:default": {},')

    return _format_branches(branches)

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
    is_proc_macro = cargo_toml_is_proc_macro(cargo_toml)
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
            "name": repr(name),
            "version": repr(version),
        },
    )

_RUST_CRATE_MACRO_CALL = """{indent}rust_crate(
{indent}    name = {name},
{indent}    crate_name = {crate_name},
{indent}    purl = {purl},
{indent}    version = {version},
{indent}    deps = [
{indent}        {deps}
{indent}    ]{extra_deps},
{indent}    link_deps = [
{indent}        {link_deps}
{indent}    ],
{indent}    data = [
{indent}        {data}
{indent}    ],
{extra_compile_data_attr}{indent}    crate_root = {crate_root},
{indent}    edition = {edition},
{indent}    rustc_env = {rustc_env},
{indent}    rustc_flags = {rustc_flags}{conditional_rustc_flags},
{indent}    tags = {tags},
{indent}    links = {links},
{indent}    build_script = {build_script},
{indent}    build_script_data = {build_script_data}{conditional_build_script_data},
{indent}    build_script_env = {build_script_env}{conditional_build_script_env},
{indent}    build_script_env_files = {build_script_env_files},
{indent}    allow_build_script_to_detect_nonhermetic_paths = {allow_build_script_to_detect_nonhermetic_paths},
{indent}    build_script_toolchains = {build_script_toolchains},
{indent}    build_script_tools = {build_script_tools}{conditional_build_script_tools},
{indent}    build_script_tags = {build_script_tags},
{indent}    is_proc_macro = {is_proc_macro},
{indent}    has_lib = {has_lib},
{indent}    binaries = {binaries},
{indent}    use_legacy_rules_rust_platforms = {use_legacy_rules_rust_platforms},
{indent}    configurations = {configurations},
{indent}    cargo_target_triple_map = {cargo_target_triple_map},
{indent}    hub_name = {hub_name},
{skip_deps_verification_attr}{indent})
"""

def render_rust_crate_call(attr, values, bazel_metadata = {}, extra_deps = "", indent = "", skip_deps_verification = False):
    use_legacy_rules_rust_platforms = attr.use_legacy_rules_rust_platforms
    if bazel_metadata.get("deps"):
        for cargo_target_triple in attr.cargo_target_triple_map:
            if cargo_target_triple:
                fail("Declare package.metadata.bazel.deps in crate.annotation(deps = ...) so Cargo configuration sharing accounts for these dependencies.")
    deps = [str(dep) for dep in attr.deps] + bazel_metadata.get("deps", [])

    build_script_data, conditional_build_script_data = render_select(attr.build_script_data, attr.build_script_data_select, use_legacy_rules_rust_platforms)
    build_script_tools, conditional_build_script_tools = render_select(attr.build_script_tools, attr.build_script_tools_select, use_legacy_rules_rust_platforms)
    rustc_flags, conditional_rustc_flags = render_select(attr.rustc_flags, attr.rustc_flags_select, use_legacy_rules_rust_platforms)
    build_script_env_files = getattr(attr, "build_script_env_files", []) + ["cargo_toml_env_vars.env"]
    link_deps = getattr(attr, "link_deps", [])

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
    cargo_manifest_env = {"CARGO_MANIFEST_PATH": "$(execpath :Cargo.toml)"}
    rustc_env = cargo_manifest_env | attr.rustc_env
    skip_deps_verification_attr = "%s    skip_deps_verification = True,\n" % indent if skip_deps_verification else ""

    return _RUST_CRATE_MACRO_CALL.format(
        indent = indent,
        deps = list_indent.join(['"%s"' % d for d in sorted(deps)]),
        extra_deps = extra_deps,
        link_deps = list_indent.join(['"%s"' % d for d in sorted(link_deps)]),
        data = list_indent.join(['"%s"' % str(d) for d in attr.data]),
        extra_compile_data_attr = extra_compile_data_attr,
        rustc_env = repr(rustc_env),
        rustc_flags = repr(rustc_flags),
        conditional_rustc_flags = " + " + conditional_rustc_flags if conditional_rustc_flags else "",
        tags = repr(attr.crate_tags),
        build_script_data = repr(build_script_data),
        conditional_build_script_data = " + " + conditional_build_script_data if conditional_build_script_data else "",
        build_script_env = repr(cargo_manifest_env | attr.build_script_env),
        conditional_build_script_env = " | " + conditional_build_script_env if conditional_build_script_env else "",
        build_script_env_files = repr([str(f) for f in build_script_env_files]),
        allow_build_script_to_detect_nonhermetic_paths = repr(attr.allow_build_script_to_detect_nonhermetic_paths),
        build_script_toolchains = repr([str(t) for t in attr.build_script_toolchains]),
        build_script_tools = repr(build_script_tools),
        conditional_build_script_tools = " + " + conditional_build_script_tools if conditional_build_script_tools else "",
        build_script_tags = repr(attr.build_script_tags),
        use_legacy_rules_rust_platforms = use_legacy_rules_rust_platforms,
        configurations = repr(json.decode(attr.configurations)),
        cargo_target_triple_map = repr(attr.cargo_target_triple_map),
        hub_name = repr(attr.hub_name),
        skip_deps_verification_attr = skip_deps_verification_attr,
        **values
    )

def render_build_file_content(rctx, attr, values, bazel_metadata = {}):
    additive_build_file_content = ""
    if attr.additive_build_file:
        additive_build_file_content += rctx.read(attr.additive_build_file)
    additive_build_file_content += attr.additive_build_file_content
    additive_build_file_content += bazel_metadata.get("additive_build_file_content", "")

    return """\
load("@rules_rs//rs/private:rust_crate.bzl", "rust_crate")
load("@rules_rs//rs:rust_binary.bzl", "rust_binary")

{rust_crate_call}""".format(
        rust_crate_call = render_rust_crate_call(attr, values, bazel_metadata = bazel_metadata),
    ) + additive_build_file_content

rust_crate_attrs = {
    "hub_name": attr.string(),
    "gen_build_script": attr.string(),
    "build_script_data": attr.label_list(),
    "build_script_data_select": _label_list_dict(),
    "build_script_env": attr.string_dict(),
    "build_script_env_select": attr.string_dict(),
    "build_script_env_files": attr.label_list(
        allow_files = True,
    ),
    "allow_build_script_to_detect_nonhermetic_paths": attr.bool(default = False),
    "build_script_toolchains": attr.label_list(),
    "build_script_tools": attr.label_list(),
    "build_script_tools_select": _label_list_dict(),
    "build_script_tags": attr.string_list(),
    "rustc_env": attr.string_dict(),
    "rustc_flags": attr.string_list(),
    "rustc_flags_select": attr.string_list_dict(),
    "crate_tags": attr.string_list(),
    "data": attr.label_list(),
    "deps": attr.label_list(),
    "link_deps": attr.string_list(),
    "cargo_target_triple_map": attr.string_dict(),
    "configurations": attr.string(mandatory = True),
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
