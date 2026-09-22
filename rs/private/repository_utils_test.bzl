"""Tests for Cargo configuration data in generated BUILD files."""

load("@bazel_skylib//lib:unittest.bzl", "asserts", "unittest")
load(":repository_utils.bzl", "render_rust_crate_call")

_LINUX = "x86_64-unknown-linux-gnu"
_MACOS = "aarch64-apple-darwin"

def _attrs(configurations = None, context_map = {}, **kwargs):
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
        hub_name = "crates",
        rustc_flags = [],
        rustc_flags_select = {},
        use_legacy_rules_rust_platforms = False,
    )
    if configurations != None:
        for key in ["aliases", "build_script_deps", "build_script_deps_select", "crate_features", "crate_features_select", "deps_select"]:
            fields.pop(key)
        fields["resolved_crates"] = json.encode({
            "context_map": context_map,
            "definitions": configurations,
        })
    fields.update(kwargs)
    return struct(**fields)

def _definition(**kwargs):
    return dict(
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

def _argument(rendered, name):
    return json.decode(rendered.split("    " + name + " = ")[1].split(",\n")[0])

def _build_scripts(rendered):
    return _argument(rendered, "build_scripts")

def _single_crate_test_impl(ctx):
    env = unittest.begin(ctx)
    definitions = {
        "": _definition(
            crate_features_select = {_LINUX: ["normal_feature"]},
            deps_select = {_LINUX: ["@dependency//:normal"]},
            build_deps_by_target = {_LINUX: {_MACOS: ["@helper//:helper"]}},
        ),
        _LINUX: _definition(
            crate_features_select = {_MACOS: ["build_feature"]},
            deps_select = {_MACOS: ["@dependency//:build"]},
        ),
    }
    context_map = {"": "", _LINUX: _LINUX, _MACOS: _LINUX}
    binaries = {"example-cli": "src/main.rs"}
    rendered = render_rust_crate_call(
        _attrs(configurations = definitions, context_map = context_map),
        _values(binaries = binaries),
    )
    asserts.equals(env, 1, rendered.count("rust_crate("))
    asserts.equals(env, definitions, _argument(rendered, "configurations"))
    asserts.equals(env, context_map, _argument(rendered, "cargo_contexts"))
    asserts.equals(env, binaries, _argument(rendered, "binaries"))
    asserts.equals(env, "crates", _argument(rendered, "hub_name"))
    asserts.false(env, "name_suffix" in rendered)
    asserts.false(env, "_exec" in rendered)
    asserts.equals(env, 1, rendered.count("normal_feature"))
    asserts.equals(env, [], _build_scripts(rendered))
    return unittest.end(env)

def _separate_build_aliases_test_impl(ctx):
    env = unittest.begin(ctx)
    definition = _definition(
        crate_features_select = {_LINUX: [], _MACOS: []},
        aliases = {"@normal//:normal": "renamed"},
        deps_select = {_LINUX: ["@normal//:normal"], _MACOS: ["@normal//:normal"]},
        build_deps_by_target = {
            _LINUX: {_MACOS: ["@build//:linux"]},
            _MACOS: {_MACOS: ["@build//:macos"]},
        },
        build_aliases_by_target = {
            _LINUX: {"@build//:linux": "renamed_build"},
            _MACOS: {"@build//:macos": "renamed_build"},
        },
    )
    rendered = render_rust_crate_call(_attrs(configurations = {"": definition}), _values())
    asserts.equals(env, {"": definition}, _argument(rendered, "configurations"))
    aliases = rendered.split("    aliases = ")[1].split("    build_aliases = ")[0]
    asserts.false(env, "@build//:" in aliases)
    asserts.equals(env, 1, rendered.count('"@normal//:normal": "renamed"'))
    return unittest.end(env)

def _annotation_and_git_values_test_impl(ctx):
    env = unittest.begin(ctx)
    values = _values() | {
        "binaries": "binaries",
        "build_script": "build_script",
        "crate_name": "crate_name",
        "has_lib": "has_lib",
        "is_proc_macro": "is_proc_macro",
    }
    rendered = render_rust_crate_call(
        _attrs(configurations = {"": _definition()}, deps = ["//annotated:dep"]),
        values,
        bazel_metadata = {"deps": ["//metadata:dep"]},
        extra_deps = "package_metadata_bazel_deps",
        indent = "    ",
    )
    for name in ["binaries", "build_script", "has_lib", "is_proc_macro"]:
        asserts.true(env, "        " + name + " = " + name + "," in rendered)
    asserts.true(env, "crate_name = crate_name or" in rendered)
    asserts.true(env, '"//annotated:dep"' in rendered)
    asserts.true(env, '"//metadata:dep"' in rendered)
    asserts.true(env, " + package_metadata_bazel_deps" in rendered)
    asserts.equals(env, 1, rendered.count("rust_crate("))
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

    rendered = render_rust_crate_call(
        _attrs(
            crate_features = ["shared"],
            crate_features_select = {_LINUX: ["gnu"], "x86_64-unknown-linux-musl": ["musl"], _MACOS: []},
            use_legacy_rules_rust_platforms = True,
        ),
        _values(),
    )
    asserts.true(env, 'crate_features = ["shared"] + select({' in rendered)
    asserts.true(env, '"@rules_rust//rust/platform:%s": ["musl"]' % _LINUX in rendered)
    asserts.false(env, '"@rules_rust//rust/platform:%s": ["gnu"]' % _LINUX in rendered)
    return unittest.end(env)

def _empty_build_matrices_test_impl(ctx):
    env = unittest.begin(ctx)
    definition = _definition(
        build_deps_by_target = {_LINUX: {_LINUX: [], _MACOS: []}},
        build_aliases_by_target = {_LINUX: {}},
    )
    for build_script in [repr("build.rs"), "None"]:
        rendered = render_rust_crate_call(
            _attrs(configurations = {"": definition}),
            _values() | {"build_script": build_script},
        )
        asserts.equals(env, {"": definition}, _argument(rendered, "configurations"))
        asserts.equals(env, [], _build_scripts(rendered))
    return unittest.end(env)

_single_crate_test = unittest.make(_single_crate_test_impl)
_separate_build_aliases_test = unittest.make(_separate_build_aliases_test_impl)
_annotation_and_git_values_test = unittest.make(_annotation_and_git_values_test_impl)
_legacy_attributes_test = unittest.make(_legacy_attributes_test_impl)
_empty_build_matrices_test = unittest.make(_empty_build_matrices_test_impl)

def repository_utils_tests():
    return unittest.suite(
        "repository_utils_tests",
        _single_crate_test,
        _separate_build_aliases_test,
        _annotation_and_git_values_test,
        _legacy_attributes_test,
        _empty_build_matrices_test,
    )
