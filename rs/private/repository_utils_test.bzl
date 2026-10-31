"""Tests for generated crate BUILD file rendering."""

load("@bazel_skylib//lib:unittest.bzl", "asserts", "unittest")
load(":repository_utils.bzl", "render_build_file_content")

_CC_LIBRARY_LOAD = 'load("@rules_cc//cc:cc_library.bzl", "cc_library")'

def _attr(additive_build_file_content = ""):
    return struct(
        additive_build_file = None,
        additive_build_file_content = additive_build_file_content,
        aliases = {},
        allow_build_script_to_detect_nonhermetic_paths = False,
        build_script_data = [],
        build_script_data_select = {},
        build_script_deps = [],
        build_script_deps_select = {},
        build_script_env = {},
        build_script_env_select = {},
        build_script_tags = [],
        build_script_toolchains = [],
        build_script_tools = [],
        build_script_tools_select = {},
        crate_features = [],
        crate_features_select = {},
        crate_tags = [],
        crate_visibility = ["//visibility:public"],
        data = [],
        deps = [],
        deps_select = {},
        hub_name = "test_hub",
        rustc_flags = [],
        rustc_flags_select = {},
        use_legacy_rules_rust_platforms = False,
    )

def _values():
    return {
        "binaries": [],
        "build_script": None,
        "crate_name": "test_crate",
        "crate_root": "src/lib.rs",
        "edition": "2021",
        "has_lib": True,
        "is_proc_macro": False,
        "links": None,
        "name": "test_crate-0.1.0",
        "purl": "pkg:cargo/test_crate@0.1.0",
        "version": "0.1.0",
    }

def _cc_library_load_is_emitted_when_additive_content_uses_cc_library_impl(ctx):
    env = unittest.begin(ctx)

    content = render_build_file_content(
        None,
        _attr(additive_build_file_content = 'cc_library(name = "test_cc")\n'),
        _values(),
    )

    asserts.true(env, _CC_LIBRARY_LOAD in content)

    return unittest.end(env)

def _cc_library_load_is_omitted_without_cc_library_usage_impl(ctx):
    env = unittest.begin(ctx)

    content = render_build_file_content(None, _attr(), _values())

    asserts.false(env, _CC_LIBRARY_LOAD in content)

    return unittest.end(env)

_cc_library_load_is_emitted_when_additive_content_uses_cc_library_test = unittest.make(_cc_library_load_is_emitted_when_additive_content_uses_cc_library_impl)
_cc_library_load_is_omitted_without_cc_library_usage_test = unittest.make(_cc_library_load_is_omitted_without_cc_library_usage_impl)

def repository_utils_tests():
    return unittest.suite(
        "repository_utils_tests",
        _cc_library_load_is_emitted_when_additive_content_uses_cc_library_test,
        _cc_library_load_is_omitted_without_cc_library_usage_test,
    )
