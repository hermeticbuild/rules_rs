"""Tests for target and execution dependency labels in generated BUILD files."""

load("@bazel_skylib//lib:unittest.bzl", "asserts", "unittest")
load(":repository_utils.bzl", "render_rust_crate_call")

_LINUX = "x86_64-unknown-linux-gnu"
_MACOS = "aarch64-apple-darwin"

def _attrs(legacy = False, **kwargs):
    fields = dict(
        aliases = {},
        allow_build_script_to_detect_nonhermetic_paths = False,
        build_script_aliases = {},
        build_script_data = [],
        build_script_data_select = {},
        build_script_deps = [],
        build_script_deps_select = {_LINUX: []},
        build_script_env = {},
        build_script_env_select = {},
        build_script_tags = [],
        build_script_toolchains = [],
        build_script_tools = [],
        build_script_tools_select = {},
        crate_features = [],
        crate_features_select = {_LINUX: []},
        crate_tags = [],
        data = [],
        deps = [],
        deps_select = {_LINUX: []},
        exec_active = False,
        exec_aliases = {},
        exec_build_script_aliases = {},
        exec_build_script_deps_select = {_LINUX: []},
        exec_crate_features_select = {_LINUX: []},
        exec_deps_select = {_LINUX: []},
        rustc_flags = [],
        rustc_flags_select = {},
        split_exec = False,
        target_active = True,
        use_legacy_rules_rust_platforms = False,
    )
    fields.update(kwargs)
    if legacy:
        for key in fields.keys():
            if key.startswith("exec_") or key in ["build_script_aliases", "split_exec", "target_active"]:
                fields.pop(key)
    return struct(**fields)

def _values(binaries = {}):
    return {
        "binaries": repr(binaries),
        "build_script": repr("build.rs"),
        "crate_name": "None",
        "crate_root": repr("src/lib.rs"),
        "edition": repr("2021"),
        "has_lib": "True",
        "is_proc_macro": "False",
        "links": "None",
        "name": repr("example"),
        "purl": repr("pkg:cargo/example@1.0.0"),
        "version": repr("1.0.0"),
    }

def _split_dependency_labels_test_impl(ctx):
    env = unittest.begin(ctx)
    rendered = render_rust_crate_call(
        _attrs(
            exec_active = True,
            split_exec = True,
            crate_features_select = {_LINUX: ["shared_feature"]},
            exec_crate_features_select = {_LINUX: ["shared_feature"]},
            deps_select = {_LINUX: ["@dependency//:dependency"]},
            exec_deps_select = {_LINUX: ["@dependency//:dependency_exec"]},
            build_script_deps_select = {_LINUX: ["@helper//:helper_exec"]},
            exec_build_script_deps_select = {_LINUX: ["@helper//:helper_exec"]},
        ),
        _values(binaries = {"example-cli": "src/main.rs"}),
    )
    calls = rendered.split("rust_crate(")[1:]
    asserts.equals(env, 2, len(calls))
    target_call, exec_call = calls
    asserts.true(env, 'name = "example",' in target_call)
    asserts.true(env, 'name = "example" + "_exec",' in exec_call)
    asserts.false(env, "_target" in rendered)
    asserts.true(env, '"@dependency//:dependency"' in target_call)
    asserts.false(env, '"@dependency//:dependency_exec"' in target_call)
    asserts.true(env, '"@dependency//:dependency_exec"' in exec_call)
    asserts.true(env, '"@helper//:helper_exec"' in target_call)
    asserts.true(env, '"@helper//:helper_exec"' in exec_call)
    asserts.true(env, 'binaries = {"example-cli": "src/main.rs"}' in target_call)
    asserts.true(env, "binaries = {}" in exec_call)
    asserts.true(env, "target_compatible_with = RESOLVED_PLATFORMS" in target_call)
    asserts.true(env, "target_compatible_with = None" in exec_call)
    return unittest.end(env)

def _separate_build_aliases_test_impl(ctx):
    env = unittest.begin(ctx)
    rendered = render_rust_crate_call(
        _attrs(
            exec_active = True,
            split_exec = True,
            aliases = {"@normal//:normal": "renamed"},
            build_script_aliases = {"@build//:build_exec": "renamed_build"},
            exec_aliases = {"@normal//:normal_exec": "renamed"},
            exec_build_script_aliases = {"@build//:build_exec": "renamed_build"},
            deps_select = {_LINUX: ["@normal//:normal"]},
            exec_deps_select = {_LINUX: ["@normal//:normal_exec"]},
            build_script_deps_select = {_LINUX: ["@build//:build_exec"]},
            exec_build_script_deps_select = {_LINUX: ["@build//:build_exec"]},
        ),
        _values(),
    )
    target_call, exec_call = rendered.split("rust_crate(")[1:]
    for call, normal_label in [(target_call, "@normal//:normal"), (exec_call, "@normal//:normal_exec")]:
        aliases = call.split("    aliases = ")[1].split("    build_aliases = ")[0]
        build_aliases = call.split("    build_aliases = ")[1].split("    deps = ")[0]
        asserts.true(env, '"%s": "renamed"' % normal_label in aliases)
        asserts.false(env, "@build//:build_exec" in aliases)
        asserts.true(env, '"@build//:build_exec": "renamed_build"' in build_aliases)
        asserts.false(env, "@normal//:" in build_aliases)
    return unittest.end(env)

def _merged_resolutions_test_impl(ctx):
    env = unittest.begin(ctx)
    rendered = render_rust_crate_call(
        _attrs(
            exec_active = True,
            crate_features_select = {_LINUX: ["shared", "dep:target_optional"]},
            exec_crate_features_select = {
                _LINUX: ["shared", "dep:exec_optional"],
                _MACOS: ["shared", "macos"],
            },
            deps_select = {_LINUX: ["@normal//:normal"]},
            exec_deps_select = {_LINUX: ["@normal//:normal"], _MACOS: ["@macos//:macos"]},
            aliases = {"@normal//:normal": "normal_alias"},
            exec_aliases = {"@macos//:macos": "macos_alias"},
            build_script_aliases = {"@build//:build": "build_alias"},
            exec_build_script_aliases = {"@macos_build//:macos_build": "macos_build_alias"},
        ),
        _values(),
    )
    asserts.equals(env, 1, len(rendered.split("rust_crate(")[1:]))
    asserts.true(env, 'name = "example",' in rendered)
    asserts.false(env, 'name_suffix = "_exec"' in rendered)
    asserts.false(env, "dep:" in rendered)
    asserts.true(env, 'crate_features = ["shared"]' in rendered)
    asserts.true(env, 'conditional_crate_features = {"%s": ["macos"]}' % _MACOS in rendered)
    asserts.true(env, "target_compatible_with = None" in rendered)
    for alias in ["normal_alias", "macos_alias", "build_alias", "macos_build_alias"]:
        asserts.true(env, alias in rendered)
    return unittest.end(env)

def _exec_only_resolution_test_impl(ctx):
    env = unittest.begin(ctx)
    rendered = render_rust_crate_call(
        _attrs(
            target_active = False,
            exec_active = True,
            crate_features_select = {},
            exec_crate_features_select = {_MACOS: ["exec_feature"]},
            exec_deps_select = {_MACOS: ["@normal//:normal_exec"]},
            exec_build_script_deps_select = {_MACOS: ["@build//:build_exec"]},
            exec_aliases = {"@normal//:normal_exec": "normal_alias"},
            exec_build_script_aliases = {"@build//:build_exec": "build_alias"},
        ),
        _values(),
    )
    asserts.equals(env, 1, len(rendered.split("rust_crate(")[1:]))
    asserts.true(env, 'name = "example",' in rendered)
    asserts.true(env, 'crate_features = ["exec_feature"]' in rendered)
    asserts.true(env, 'triples = ["%s"]' % _MACOS in rendered)
    asserts.true(env, '"@normal//:normal_exec": "normal_alias"' in rendered)
    asserts.true(env, '"@build//:build_exec": "build_alias"' in rendered)
    asserts.true(env, "target_compatible_with = None" in rendered)
    return unittest.end(env)

def _legacy_attributes_test_impl(ctx):
    env = unittest.begin(ctx)
    rendered = render_rust_crate_call(
        _attrs(legacy = True, aliases = {"@dependency//:dependency": "renamed"}),
        _values(),
        extra_deps = "package_metadata_bazel_deps",
        skip_deps_verification = True,
    )
    asserts.equals(env, 2, len(rendered.split('"@dependency//:dependency": "renamed"')) - 1)
    asserts.true(env, " + package_metadata_bazel_deps" in rendered)
    asserts.true(env, "skip_deps_verification = True" in rendered)
    asserts.true(env, "target_compatible_with = RESOLVED_PLATFORMS" in rendered)
    return unittest.end(env)

_split_dependency_labels_test = unittest.make(_split_dependency_labels_test_impl)
_separate_build_aliases_test = unittest.make(_separate_build_aliases_test_impl)
_merged_resolutions_test = unittest.make(_merged_resolutions_test_impl)
_exec_only_resolution_test = unittest.make(_exec_only_resolution_test_impl)
_legacy_attributes_test = unittest.make(_legacy_attributes_test_impl)

def repository_utils_tests():
    return unittest.suite(
        "repository_utils_tests",
        _split_dependency_labels_test,
        _separate_build_aliases_test,
        _merged_resolutions_test,
        _exec_only_resolution_test,
        _legacy_attributes_test,
    )
