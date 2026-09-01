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
        link_deps = [],
        tags = [],
        crate_features = [],
        crate_features_select = {},
        gen_binaries = [],
        extra_aliased_targets = {},
        rustc_env = {},
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
        link_deps = link_deps,
        tags = tags,
        crate_features = crate_features,
        crate_features_select = crate_features_select,
        gen_binaries = gen_binaries,
        extra_aliased_targets = extra_aliased_targets,
        rustc_env = rustc_env,
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
        if crate_name in _WINDOWS_GNULLVM_CRATES:
            implicit = _windows_gnullvm_implicit_annotation(crate_name, version, hub_name)
            values = structs.to_dict(implicit)
            defaults = structs.to_dict(_DEFAULT_CRATE_ANNOTATION)
            for field, value in structs.to_dict(annotation).items():
                # Tag-class string attributes use "" where the internal
                # annotation representation uses None.
                if value == defaults.get(field) or (value == "" and defaults.get(field) == None):
                    continue
                if field == "deps":
                    values[field] += value
                elif field == "extra_aliased_targets":
                    values[field].update(value)
                elif field == "additive_build_file_content":
                    values[field] += value
                else:
                    values[field] = value
            return _crate_annotation(**values)
        return annotation

    if crate_name in _WINDOWS_GNULLVM_CRATES:
        return _windows_gnullvm_implicit_annotation(crate_name, version, hub_name)
    return _DEFAULT_CRATE_ANNOTATION

_SELECTABLE_ANNOTATION_FIELDS = {
    "build_script_data": "build_script_data_select",
    "build_script_env": "build_script_env_select",
    "build_script_tools": "build_script_tools_select",
    "crate_features": "crate_features_select",
    "rustc_flags": "rustc_flags_select",
}

_LIST_SELECT_FIELDS = [
    select_field
    for field, select_field in _SELECTABLE_ANNOTATION_FIELDS.items()
    if field != "build_script_env"
]

_SELECT_MAP_FIELDS = _SELECTABLE_ANNOTATION_FIELDS.values()

def _annotation_values(annotation):
    values = structs.to_dict(annotation)
    for field in ["crate", "repositories", "triples", "version"]:
        values.pop(field, None)
    return values

def _merge_annotation_select(selects, annotation, crate, version, cfg_name):
    selected_values = _annotation_values(annotation)
    for field, select_field in _SELECTABLE_ANNOTATION_FIELDS.items():
        value = selected_values.get(field)
        if not value:
            continue

        # Stringify labels only after tag resolution has anchored them to the
        # module that declared the annotation. Keep environment values as
        # dictionaries so wildcard and exact selections can compose by key.
        selected_value = dict(value) if field == "build_script_env" else [str(item) for item in value]
        platform_values = dict(selects.get(select_field, {}))
        for triple in annotation.triples:
            if triple in platform_values:
                fail("Duplicate crate.annotation_select for %s version %s triple %s field %s in repo %s" % (crate, version, triple, field, cfg_name))
            platform_values[triple] = selected_value
        selects[select_field] = platform_values

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

def _merge_select_maps(base, override):
    for field in _SELECT_MAP_FIELDS:
        if field not in override:
            continue
        selected = dict(base.get(field, {}))
        for triple, value in override[field].items():
            if triple not in selected:
                selected[triple] = value
            elif field == "build_script_env_select":
                merged = dict(selected[triple])
                merged.update(value)
                selected[triple] = merged
            else:
                selected[triple] = selected[triple] + value
        base[field] = selected

def _normalize_select_maps(values):
    for field in _LIST_SELECT_FIELDS:
        values[field] = {
            triple: [str(item) for item in items]
            for triple, items in values.get(field, {}).items()
        }
    values["build_script_env_select"] = {
        triple: json.decode(env) if type(env) == "string" else dict(env)
        for triple, env in values.get("build_script_env_select", {}).items()
    }

def _encode_env_select(values):
    values["build_script_env_select"] = {
        triple: json.encode(env)
        for triple, env in values.get("build_script_env_select", {}).items()
    }

def _annotation_entry():
    return {
        "annotation": None,
        "selects": {},
    }

def build_annotation_map(mod, cfg_name, platform_triples):
    """Build mapping {crate: {version|\"*\": annotation}} for a cfg name."""
    annotations = {}
    for annotation in mod.tags.annotation:
        if annotation.repositories and cfg_name not in annotation.repositories:
            continue

        version_key = annotation.version or "*"
        crate_map = annotations.setdefault(annotation.crate, {})
        entry = crate_map.setdefault(version_key, _annotation_entry())
        if entry["annotation"] != None:
            fail("Duplicate crate.annotation for %s version %s in repo %s" % (annotation.crate, version_key, cfg_name))
        entry["annotation"] = _annotation_values(annotation)

    for annotation in mod.tags.annotation_select:
        if annotation.repositories and cfg_name not in annotation.repositories:
            continue

        version_key = annotation.version or "*"
        crate_map = annotations.setdefault(annotation.crate, {})
        entry = crate_map.setdefault(version_key, _annotation_entry())
        _merge_annotation_select(entry["selects"], annotation, annotation.crate, version_key, cfg_name)

    for crate_map in annotations.values():
        wildcard_entry = crate_map.get("*")
        wildcard_annotation = wildcard_entry["annotation"] if wildcard_entry else None
        wildcard_selects = wildcard_entry["selects"] if wildcard_entry else {}
        for version, entry in crate_map.items():
            values = dict(entry["annotation"] or wildcard_annotation or structs.to_dict(_DEFAULT_CRATE_ANNOTATION))
            _normalize_select_maps(values)
            selects = {}
            _merge_select_maps(selects, wildcard_selects)
            if version != "*":
                _merge_select_maps(selects, entry["selects"])
            _merge_select_maps(values, selects)
            _fill_select_defaults(values, platform_triples)
            _encode_env_select(values)
            crate_map[version] = _crate_annotation(**values)
    return annotations

def well_known_annotation_snippet_paths(mctx):
    """Returns {crate: snippet_path} for crates with include.MODULE.bazel snippets."""
    return {
        crate_dir.basename: crate_dir.get_child("include.MODULE.bazel")
        for crate_dir in mctx.path(Label("//:3rd_party")).readdir()
    }
