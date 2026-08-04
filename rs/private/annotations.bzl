load("@bazel_skylib//lib:structs.bzl", "structs")

def _crate_annotation(
        additive_build_file = None,
        additive_build_file_content = "",
        gen_build_script = "auto",
        build_script_data = [],
        build_script_data_select = {},
        build_script_env = {},
        build_script_env_select = {},
        build_script_env_files = [],
        allow_build_script_to_detect_nonhermetic_paths = False,
        build_script_tools = [],
        build_script_tools_select = {},
        build_script_toolchains = [],
        build_script_tags = [],
        data = [],
        deps = [],
        tags = [],
        crate_features = [],
        crate_features_select = {},
        gen_binaries = [],
        extra_aliased_targets = {},
        rustc_flags = [],
        rustc_flags_select = {},
        patch_args = [],
        patch_tool = None,
        patches = [],
        strip_prefix = None,
        workspace_cargo_toml = "Cargo.toml"):
    return struct(
        additive_build_file = additive_build_file,
        additive_build_file_content = additive_build_file_content,
        gen_build_script = gen_build_script,
        build_script_data = build_script_data,
        build_script_data_select = build_script_data_select,
        build_script_env = build_script_env,
        build_script_env_select = build_script_env_select,
        build_script_env_files = build_script_env_files,
        allow_build_script_to_detect_nonhermetic_paths = allow_build_script_to_detect_nonhermetic_paths,
        build_script_tools = build_script_tools,
        build_script_tools_select = build_script_tools_select,
        build_script_toolchains = build_script_toolchains,
        build_script_tags = build_script_tags,
        data = data,
        deps = deps,
        tags = tags,
        crate_features = crate_features,
        crate_features_select = crate_features_select,
        gen_binaries = gen_binaries,
        extra_aliased_targets = extra_aliased_targets,
        rustc_flags = rustc_flags,
        rustc_flags_select = rustc_flags_select,
        patch_args = patch_args,
        patch_tool = patch_tool,
        patches = patches,
        strip_prefix = strip_prefix,
        workspace_cargo_toml = workspace_cargo_toml,
    )

_DEFAULT_CRATE_ANNOTATION = _crate_annotation()

_WINDOWS_GNULLVM_ADDITIVE_BUILD_FILE_CONTENT = """
load("@rules_cc//cc:defs.bzl", "cc_import")

cc_import(
    name = "windows_import_lib",
    static_library = glob(["lib/*.a"])[0],
    visibility = ["//visibility:public"],
)
"""

def _windows_gnullvm_implicit_annotation(crate_name, version, hub_name):
    alias_name = crate_name + "_import_lib"
    return _crate_annotation(
        additive_build_file_content = _WINDOWS_GNULLVM_ADDITIVE_BUILD_FILE_CONTENT,
        gen_build_script = "off",
        deps = ["@%s//:%s-%s" % (hub_name, alias_name, version)],
        extra_aliased_targets = {
            alias_name: "windows_import_lib",
        },
    )

_WINDOWS_GNULLVM_CRATES = [
    # These crates publish the needed import library in their package archive.
    # Apply the annotation by default so users do not need to add it.
    "windows_aarch64_gnullvm",
    "windows_x86_64_gnullvm",
]

def annotation_for(annotations_by_crate, crate_name, version, hub_name):
    """Return the annotation matching crate/version, falling back to '*' or default."""
    version_map = annotations_by_crate.get(crate_name, {})
    annotation = version_map.get(version) or version_map.get("*")
    if annotation:
        return annotation

    if crate_name in _WINDOWS_GNULLVM_CRATES:
        return _windows_gnullvm_implicit_annotation(crate_name, version, hub_name)
    return _DEFAULT_CRATE_ANNOTATION

_SELECTABLE_ANNOTATION_FIELDS = {
    "build_script_data": "build_script_data_select",
    "build_script_env": "build_script_env_select",
    "build_script_tools": "build_script_tools_select",
    "crate_features": "crate_features_select",
    "deps": "deps_select",
    "link_deps": "link_deps_select",
    "rustc_flags": "rustc_flags_select",
}

_LIST_SELECT_FIELDS = [
    "build_script_data_select",
    "build_script_tools_select",
    "crate_features_select",
    "deps_select",
    "link_deps_select",
    "rustc_flags_select",
    "target_compatible_with_select",
]

def _annotation_values(annotation):
    values = structs.to_dict(annotation)
    for field in ["crate", "repositories", "triples", "version"]:
        values.pop(field, None)
    return values

def _merge_annotation_select(values, annotation, crate, version, cfg_name):
    selected_values = _annotation_values(annotation)
    for field, select_field in _SELECTABLE_ANNOTATION_FIELDS.items():
        value = selected_values.get(field)
        if not value:
            continue

        platform_values = dict(values.get(select_field, {}))
        for triple in annotation.triples:
            if triple in platform_values:
                fail("Duplicate crate.annotation_select for %s version %s triple %s field %s in repo %s" % (crate, version, triple, field, cfg_name))
            platform_values[triple] = json.encode(value) if field == "build_script_env" else value
        values[select_field] = platform_values

def _fill_select_defaults(values, platform_triples):
    # Keep explicitly selected values conditional, including empty branches.
    for field in _LIST_SELECT_FIELDS:
        platform_values = values.get(field)
        if not platform_values:
            continue

        platform_values = dict(platform_values)
        for triple in platform_triples:
            platform_values.setdefault(triple, [])
        values[field] = platform_values

def build_annotation_map(mod, cfg_name, platform_triples):
    """Build mapping {crate: {version|\"*\": annotation}} for a cfg name."""
    annotations = {}
    for annotation in mod.tags.annotation:
        if cfg_name not in (annotation.repositories or [cfg_name]):
            continue

        version_key = annotation.version or "*"
        crate_map = annotations.setdefault(annotation.crate, {})
        if version_key in crate_map:
            fail("Duplicate crate.annotation for %s version %s in repo %s" % (annotation.crate, version_key, cfg_name))
        crate_map[version_key] = _annotation_values(annotation)

    for annotation in mod.tags.annotation_select:
        if cfg_name not in (annotation.repositories or [cfg_name]):
            continue

        version_key = annotation.version or "*"
        crate_map = annotations.setdefault(annotation.crate, {})
        values = crate_map.setdefault(version_key, structs.to_dict(_DEFAULT_CRATE_ANNOTATION))
        _merge_annotation_select(values, annotation, annotation.crate, version_key, cfg_name)

    for crate_map in annotations.values():
        for version, values in crate_map.items():
            _fill_select_defaults(values, platform_triples)
            crate_map[version] = _crate_annotation(**values)
    return annotations

def well_known_annotation_snippet_paths(mctx):
    """Returns {crate: snippet_path} for crates with include.MODULE.bazel snippets."""
    return {
        crate_dir.basename: crate_dir.get_child("include.MODULE.bazel")
        for crate_dir in mctx.path(Label("//:3rd_party")).readdir()
    }
