"""Tests for target and execution dependency labels in generated BUILD files."""

load("@bazel_skylib//lib:unittest.bzl", "asserts", "unittest")
load(":repository_utils.bzl", "render_rust_crate_call")

_LINUX = "x86_64-unknown-linux-gnu"
_MACOS = "aarch64-apple-darwin"

def _attrs(variants = None, **kwargs):
    fields = dict(
        aliases = {},
        allow_build_script_to_detect_nonhermetic_paths = False,
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
        rustc_flags = [],
        rustc_flags_select = {},
        use_legacy_rules_rust_platforms = False,
    )
    if variants != None:
        for key in ["aliases", "build_script_deps", "build_script_deps_select", "crate_features", "crate_features_select", "deps_select"]:
            fields.pop(key)
        fields["resolved_crates"] = json.encode(variants)
    fields.update(kwargs)
    return struct(**fields)

def _variant(**kwargs):
    return dict(
        name_suffix = "",
        crate_features_select = {_LINUX: []},
        deps_select = {_LINUX: []},
        aliases = {},
        build_deps_by_target = {},
        build_aliases_by_target = {},
    ) | kwargs

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

def _build_scripts(rendered):
    return json.decode(rendered.split("    build_scripts = ")[1].split(",\n")[0])

def _split_dependency_labels_test_impl(ctx):
    env = unittest.begin(ctx)
    build_deps = {_LINUX: {_MACOS: ["@helper//:helper_exec"]}}
    rendered = render_rust_crate_call(
        _attrs(variants = [
            _variant(
                crate_features_select = {_LINUX: ["shared_feature"]},
                deps_select = {_LINUX: ["@dependency//:dependency"]},
                build_deps_by_target = build_deps,
            ),
            _variant(
                name_suffix = "_exec",
                crate_features_select = {_LINUX: ["shared_feature"]},
                deps_select = {_LINUX: ["@dependency//:dependency_exec"]},
                build_deps_by_target = build_deps,
            ),
        ]),
        _values(binaries = {"example-cli": "src/main.rs"}),
    )
    calls = rendered.split("rust_crate(")[1:]
    asserts.equals(env, 2, len(calls))
    target_call, exec_call = calls
    asserts.true(env, 'name = "example",' in target_call)
    asserts.true(env, 'name = "example",' in exec_call)
    asserts.true(env, 'name_suffix = "_exec",' in exec_call)
    asserts.true(env, '"@dependency//:dependency"' in target_call)
    asserts.false(env, '"@dependency//:dependency_exec"' in target_call)
    asserts.true(env, '"@dependency//:dependency_exec"' in exec_call)
    asserts.equals(env, [{
        "target_triples": [_LINUX],
        "crate_features": ["shared_feature"],
        "deps": ["@helper//:helper_exec"],
        "deps_by_platform": {},
        "aliases": {},
    }], _build_scripts(target_call))
    asserts.equals(env, _build_scripts(target_call), _build_scripts(exec_call))
    asserts.true(env, 'binaries = {"example-cli": "src/main.rs"}' in target_call)
    asserts.true(env, "binaries = {}" in exec_call)
    asserts.true(env, "target_compatible_with = None" in target_call)
    asserts.true(env, "target_compatible_with = None" in exec_call)
    return unittest.end(env)

def _separate_build_aliases_test_impl(ctx):
    env = unittest.begin(ctx)
    build_deps = {
        _LINUX: {_MACOS: ["@build//:linux_exec"]},
        _MACOS: {_MACOS: ["@build//:macos_exec"]},
    }
    build_aliases = {
        _LINUX: {"@build//:linux_exec": "renamed_build"},
        _MACOS: {"@build//:macos_exec": "renamed_build"},
    }
    rendered = render_rust_crate_call(
        _attrs(variants = [
            _variant(
                crate_features_select = {_LINUX: [], _MACOS: []},
                aliases = {"@normal//:normal": "renamed"},
                deps_select = {_LINUX: ["@normal//:normal"], _MACOS: ["@normal//:normal"]},
                build_deps_by_target = build_deps,
                build_aliases_by_target = build_aliases,
            ),
        ]),
        _values(),
    )
    aliases = rendered.split("    aliases = ")[1].split("    build_aliases = ")[0]
    build_scripts = {script["target_triples"][0]: script for script in _build_scripts(rendered)}
    asserts.true(env, '"@normal//:normal": "renamed"' in aliases)
    asserts.false(env, "@build//:" in aliases)
    for triple in [_LINUX, _MACOS]:
        asserts.equals(env, build_aliases[triple], build_scripts[triple]["aliases"])
        asserts.equals(env, build_deps[triple][_MACOS], build_scripts[triple]["deps"])
        asserts.equals(env, {}, build_scripts[triple]["deps_by_platform"])
    asserts.false(env, "select(" in rendered)
    return unittest.end(env)

def _merged_resolutions_test_impl(ctx):
    env = unittest.begin(ctx)
    rendered = render_rust_crate_call(
        _attrs(variants = [
            _variant(
                crate_features_select = {
                    _LINUX: ["shared"],
                    _MACOS: ["shared", "macos"],
                },
                deps_select = {_LINUX: ["@normal//:normal"], _MACOS: ["@macos//:macos"]},
                aliases = {"@normal//:normal": "normal_alias", "@macos//:macos": "macos_alias"},
                build_deps_by_target = {
                    _LINUX: {_MACOS: ["@build//:build"]},
                    _MACOS: {_MACOS: ["@macos_build//:macos_build"]},
                },
                build_aliases_by_target = {
                    _LINUX: {"@build//:build": "build_alias"},
                    _MACOS: {"@macos_build//:macos_build": "macos_build_alias"},
                },
            ),
        ]),
        _values(),
    )
    asserts.equals(env, 1, len(rendered.split("rust_crate(")[1:]))
    asserts.true(env, "triples = " + repr(sorted([_LINUX, _MACOS])) in rendered)
    asserts.true(env, 'name = "example",' in rendered)
    asserts.false(env, 'name_suffix = "_exec"' in rendered)
    asserts.false(env, "dep:" in rendered)
    asserts.true(env, 'crate_features = ["shared"]' in rendered)
    asserts.true(env, 'conditional_crate_features = {"%s": ["macos"]}' % _MACOS in rendered)
    asserts.true(env, "target_compatible_with = None" in rendered)
    for alias in ["normal_alias", "macos_alias", "build_alias", "macos_build_alias"]:
        asserts.true(env, alias in rendered)
    return unittest.end(env)

def _legacy_attributes_test_impl(ctx):
    env = unittest.begin(ctx)
    rendered = render_rust_crate_call(
        _attrs(
            aliases = {"@dependency//:dependency": "renamed"},
            crate_features = ["shared", "dep:optional"],
            crate_features_select = {_LINUX: ["specific", "dep:another"]},
            build_script_deps_select = {_LINUX: ["@dependency//:dependency"]},
        ),
        _values(),
        extra_deps = "package_metadata_bazel_deps",
        skip_deps_verification = True,
    )
    asserts.equals(env, 2, len(rendered.split('"@dependency//:dependency": "renamed"')) - 1)
    asserts.true(env, " + package_metadata_bazel_deps" in rendered)
    asserts.true(env, 'crate_features = ["shared", "specific"]' in rendered)
    asserts.equals(env, ["shared", "specific"], _build_scripts(rendered)[0]["crate_features"])
    asserts.false(env, "dep:" in rendered)
    asserts.true(env, "skip_deps_verification = True" in rendered)
    asserts.true(env, "target_compatible_with = RESOLVED_PLATFORMS" in rendered)
    asserts.false(env, "build_deps_by_target" in rendered)
    asserts.false(env, "build_aliases_by_target" in rendered)
    return unittest.end(env)

def _empty_build_matrices_test_impl(ctx):
    env = unittest.begin(ctx)
    rendered = render_rust_crate_call(
        _attrs(variants = [
            _variant(
                build_deps_by_target = {_LINUX: {_LINUX: [], _MACOS: []}},
                build_aliases_by_target = {_LINUX: {}},
            ),
        ]),
        _values(),
    )
    asserts.false(env, "build_deps_by_target" in rendered)
    asserts.false(env, "build_aliases_by_target" in rendered)
    asserts.equals(env, [], _build_scripts(rendered)[0]["deps"])
    asserts.equals(env, {}, _build_scripts(rendered)[0]["deps_by_platform"])
    asserts.equals(env, {}, _build_scripts(rendered)[0]["aliases"])
    no_script = render_rust_crate_call(_attrs(variants = [_variant()]), _values() | {"build_script": "None"})
    asserts.equals(env, [], _build_scripts(no_script))
    return unittest.end(env)

_split_dependency_labels_test = unittest.make(_split_dependency_labels_test_impl)
_separate_build_aliases_test = unittest.make(_separate_build_aliases_test_impl)
_merged_resolutions_test = unittest.make(_merged_resolutions_test_impl)
_legacy_attributes_test = unittest.make(_legacy_attributes_test_impl)
_empty_build_matrices_test = unittest.make(_empty_build_matrices_test_impl)

def repository_utils_tests():
    return unittest.suite(
        "repository_utils_tests",
        _split_dependency_labels_test,
        _separate_build_aliases_test,
        _merged_resolutions_test,
        _legacy_attributes_test,
        _empty_build_matrices_test,
    )
