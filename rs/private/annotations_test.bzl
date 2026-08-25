load("@bazel_skylib//lib:unittest.bzl", "asserts", "unittest")
load(":annotations.bzl", "annotation_for", "apply_dependency_annotation", "build_annotation_map")

_TRIPLES = [
    "aarch64-apple-darwin",
    "x86_64-unknown-linux-gnu",
]

def _mod(annotations = [], annotation_selects = []):
    return struct(
        tags = struct(
            annotation = annotations,
            annotation_select = annotation_selects,
        ),
    )

_ANNOTATION_DEFAULTS = {
    "additive_build_file": None,
    "additive_build_file_content": "",
    "allow_build_script_to_detect_nonhermetic_paths": False,
    "build_script_data": [],
    "build_script_env": {},
    "build_script_env_files": [],
    "build_script_tags": [],
    "build_script_toolchains": [],
    "build_script_tools": [],
    "crate_features": [],
    "data": [],
    "deps": [],
    "extra_aliased_targets": {},
    "gen_binaries": [],
    "gen_build_script": "auto",
    "link_deps": [],
    "patch_args": [],
    "patch_tool": "",
    "patches": [],
    "remove_build_script_deps": [],
    "remove_deps": [],
    "rustc_flags": [],
    "strip_prefix": "",
    "tags": [],
    "target_compatible_with": [],
    "workspace_cargo_toml": "Cargo.toml",
}

_ANNOTATION_SELECT_DEFAULTS = {
    "build_script_data": [],
    "build_script_env": {},
    "build_script_tools": [],
    "crate_features": [],
    "deps": [],
    "link_deps": [],
    "rustc_flags": [],
    "target_compatible_with": [],
}

def _annotation(crate, version = "*", **kwargs):
    values = dict(_ANNOTATION_DEFAULTS)
    values.update(kwargs)
    return struct(crate = crate, repositories = [], version = version, **values)

def _annotation_select(crate, triples, version = "*", **kwargs):
    values = dict(_ANNOTATION_SELECT_DEFAULTS)
    values.update(kwargs)
    return struct(crate = crate, repositories = [], triples = triples, version = version, **values)

def _exact_annotation_replaces_wildcard_and_composes_with_select_impl(ctx):
    env = unittest.begin(ctx)
    annotations = build_annotation_map(
        _mod(
            annotations = [
                _annotation(
                    "example",
                    gen_build_script = "on",
                    link_deps = ["//:wildcard_link_dep"],
                    patches = ["//:wildcard.patch"],
                    workspace_cargo_toml = "crate/Cargo.toml",
                ),
                _annotation(
                    "example",
                    version = "1.0.0",
                    link_deps = ["//:exact_link_dep"],
                    patches = ["//:exact.patch"],
                ),
            ],
            annotation_selects = [
                _annotation_select(
                    "example",
                    ["x86_64-unknown-linux-gnu"],
                    version = "1.0.0",
                    rustc_flags = ["--cfg=exact"],
                ),
            ],
        ),
        "repo",
        _TRIPLES,
    )

    annotation = annotation_for(annotations, "example", "1.0.0", "repo")
    asserts.equals(env, "auto", annotation.gen_build_script)
    asserts.equals(env, ["//:exact_link_dep"], annotation.link_deps)
    asserts.equals(env, ["//:exact.patch"], annotation.patches)
    asserts.equals(env, "Cargo.toml", annotation.workspace_cargo_toml)
    asserts.equals(env, {
        "aarch64-apple-darwin": [],
        "x86_64-unknown-linux-gnu": ["--cfg=exact"],
    }, annotation.rustc_flags_select)

    return unittest.end(env)

def _wildcard_and_exact_select_payloads_compose_impl(ctx):
    env = unittest.begin(ctx)
    annotations = build_annotation_map(
        _mod(
            annotation_selects = [
                _annotation_select(
                    "example",
                    ["x86_64-unknown-linux-gnu"],
                    build_script_env = {"COMMON": "wildcard", "OVERRIDE": "wildcard"},
                    deps = ["//:wildcard_dep"],
                    link_deps = ["//:wildcard_link_dep"],
                    rustc_flags = ["--cfg=wildcard"],
                    target_compatible_with = ["//:wildcard_constraint"],
                ),
                _annotation_select(
                    "example",
                    ["x86_64-unknown-linux-gnu"],
                    version = "1.0.0",
                    build_script_env = {"EXACT": "exact", "OVERRIDE": "exact"},
                    deps = ["//:exact_dep"],
                    link_deps = ["//:exact_link_dep"],
                    rustc_flags = ["--cfg=exact"],
                    target_compatible_with = ["//:exact_constraint"],
                ),
            ],
        ),
        "repo",
        _TRIPLES,
    )

    annotation = annotation_for(annotations, "example", "1.0.0", "repo")
    asserts.equals(env, {
        "COMMON": "wildcard",
        "EXACT": "exact",
        "OVERRIDE": "exact",
    }, json.decode(annotation.build_script_env_select["x86_64-unknown-linux-gnu"]))
    asserts.equals(env, {
        "aarch64-apple-darwin": [],
        "x86_64-unknown-linux-gnu": ["--cfg=wildcard", "--cfg=exact"],
    }, annotation.rustc_flags_select)
    asserts.equals(env, {
        "aarch64-apple-darwin": [],
        "x86_64-unknown-linux-gnu": ["//:wildcard_dep", "//:exact_dep"],
    }, annotation.deps_select)
    asserts.equals(env, {
        "aarch64-apple-darwin": [],
        "x86_64-unknown-linux-gnu": ["//:wildcard_link_dep", "//:exact_link_dep"],
    }, annotation.link_deps_select)
    asserts.equals(env, {
        "aarch64-apple-darwin": [],
        "x86_64-unknown-linux-gnu": ["//:wildcard_constraint", "//:exact_constraint"],
    }, annotation.target_compatible_with_select)

    return unittest.end(env)

def _wildcard_select_composes_with_exact_annotation_impl(ctx):
    env = unittest.begin(ctx)
    annotations = build_annotation_map(
        _mod(
            annotations = [
                _annotation(
                    "example",
                    version = "1.0.0",
                    patches = ["//:exact.patch"],
                ),
            ],
            annotation_selects = [
                _annotation_select(
                    "example",
                    ["x86_64-unknown-linux-gnu"],
                    rustc_flags = ["--cfg=wildcard"],
                ),
            ],
        ),
        "repo",
        _TRIPLES,
    )

    annotation = annotation_for(annotations, "example", "1.0.0", "repo")
    asserts.equals(env, ["//:exact.patch"], annotation.patches)
    asserts.equals(env, {
        "aarch64-apple-darwin": [],
        "x86_64-unknown-linux-gnu": ["--cfg=wildcard"],
    }, annotation.rustc_flags_select)

    return unittest.end(env)

def _selected_windows_gnullvm_annotation_keeps_implicit_values_impl(ctx):
    env = unittest.begin(ctx)
    annotations = build_annotation_map(
        _mod(
            annotation_selects = [
                _annotation_select(
                    "windows_x86_64_gnullvm",
                    ["x86_64-unknown-linux-gnu"],
                    rustc_flags = ["--cfg=selected"],
                ),
            ],
        ),
        "repo",
        _TRIPLES,
    )

    annotation = annotation_for(annotations, "windows_x86_64_gnullvm", "0.53.0", "repo")
    asserts.equals(env, "off", annotation.gen_build_script)
    asserts.equals(env, ["@repo//:windows_x86_64_gnullvm_import_lib-0.53.0"], annotation.deps)
    asserts.equals(env, {"windows_x86_64_gnullvm_import_lib": "windows_import_lib"}, annotation.extra_aliased_targets)
    asserts.equals(env, {
        "aarch64-apple-darwin": [],
        "x86_64-unknown-linux-gnu": ["--cfg=selected"],
    }, annotation.rustc_flags_select)

    return unittest.end(env)

def _apply_dependency_annotation_removes_generated_and_adds_selected_impl(ctx):
    env = unittest.begin(ctx)
    deps_select = apply_dependency_annotation(
        {
            "aarch64-apple-darwin": ["@repo//:common", "@repo//:macos_only"],
            "x86_64-unknown-linux-gnu": ["@repo//:common", "@repo//:linux_only"],
        },
        {
            "x86_64-unknown-linux-gnu": ["//:replacement"],
            "x86_64-pc-windows-msvc": ["//:windows_only"],
        },
        ["@repo//:common", "@repo//:linux_only"],
    )

    asserts.equals(env, {
        "aarch64-apple-darwin": ["@repo//:macos_only"],
        "x86_64-pc-windows-msvc": ["//:windows_only"],
        "x86_64-unknown-linux-gnu": ["//:replacement"],
    }, deps_select)

    return unittest.end(env)

exact_annotation_replaces_wildcard_and_composes_with_select_test = unittest.make(_exact_annotation_replaces_wildcard_and_composes_with_select_impl)
wildcard_and_exact_select_payloads_compose_test = unittest.make(_wildcard_and_exact_select_payloads_compose_impl)
wildcard_select_composes_with_exact_annotation_test = unittest.make(_wildcard_select_composes_with_exact_annotation_impl)
selected_windows_gnullvm_annotation_keeps_implicit_values_test = unittest.make(_selected_windows_gnullvm_annotation_keeps_implicit_values_impl)
apply_dependency_annotation_removes_generated_and_adds_selected_test = unittest.make(_apply_dependency_annotation_removes_generated_and_adds_selected_impl)

def annotations_tests():
    return unittest.suite(
        "annotations_tests",
        exact_annotation_replaces_wildcard_and_composes_with_select_test,
        wildcard_and_exact_select_payloads_compose_test,
        wildcard_select_composes_with_exact_annotation_test,
        selected_windows_gnullvm_annotation_keeps_implicit_values_test,
        apply_dependency_annotation_removes_generated_and_adds_selected_test,
    )
