"""Tests for generated crate repository BUILD rendering."""

load("@bazel_skylib//lib:unittest.bzl", "asserts", "unittest")
load(":repository_utils.bzl", "render_rust_crate_call")

def _attr(**kwargs):
    values = {
        "aliases": {},
        "allow_build_script_to_detect_nonhermetic_paths": False,
        "build_script_data": [],
        "build_script_data_select": {},
        "build_script_deps": [],
        "build_script_deps_select": {},
        "build_script_env": {},
        "build_script_env_files": [],
        "build_script_env_select": {},
        "build_script_tags": [],
        "build_script_toolchains": [],
        "build_script_tools": [],
        "build_script_tools_select": {},
        "crate_features": [],
        "crate_features_select": {},
        "crate_tags": [],
        "data": [],
        "deps": [],
        "deps_select": {},
        "rustc_flags": [],
        "rustc_flags_select": {},
        "use_legacy_rules_rust_platforms": False,
    }
    values.update(kwargs)
    return struct(**values)

def _values():
    return {
        "binaries": "{}",
        "build_script": "None",
        "crate_name": '"example"',
        "crate_root": '"src/lib.rs"',
        "edition": '"2021"',
        "has_lib": "True",
        "is_proc_macro": "False",
        "links": "None",
        "name": '"example-1.0.0"',
        "purl": '"pkg:cargo/example@1.0.0"',
        "version": '"1.0.0"',
    }

def _render_selectable_link_deps_and_compatibility_impl(ctx):
    env = unittest.begin(ctx)
    rendered = render_rust_crate_call(
        _attr(
            link_deps = ["//:base_link"],
            link_deps_select = {
                "aarch64-apple-darwin": ["//:macos_link"],
                "x86_64-unknown-linux-gnu": [],
            },
            target_compatible_with = ["//:base_constraint"],
            target_compatible_with_select = {
                "aarch64-apple-darwin": [],
                "x86_64-unknown-linux-gnu": ["//:linux_constraint"],
            },
        ),
        _values(),
    )

    asserts.true(env, """link_deps = [
        "//:base_link"
    ] + select({
        "@rules_rs//rs/platforms/config:aarch64-apple-darwin": ["//:macos_link"],
        "//conditions:default": [],
    }),""" in rendered)
    asserts.true(env, """target_compatible_with = RESOLVED_PLATFORMS + ["//:base_constraint"] + select({
        "@rules_rs//rs/platforms/config:x86_64-unknown-linux-gnu": ["//:linux_constraint"],
        "//conditions:default": [],
    }),""" in rendered)

    return unittest.end(env)

def _render_missing_optional_fields_impl(ctx):
    env = unittest.begin(ctx)
    rendered = render_rust_crate_call(_attr(), _values())

    asserts.true(env, "target_compatible_with = RESOLVED_PLATFORMS + []," in rendered)
    asserts.true(env, "link_deps = [\n        \n    ]," in rendered)

    return unittest.end(env)

render_selectable_link_deps_and_compatibility_test = unittest.make(_render_selectable_link_deps_and_compatibility_impl)
render_missing_optional_fields_test = unittest.make(_render_missing_optional_fields_impl)

def repository_utils_tests():
    return unittest.suite(
        "repository_utils_tests",
        render_selectable_link_deps_and_compatibility_test,
        render_missing_optional_fields_test,
    )
