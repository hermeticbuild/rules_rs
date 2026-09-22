"""Tests for selecting build-script requirements before the exec transition."""

load("@bazel_skylib//lib:unittest.bzl", "loadingtest")
load("//rs:cargo_build_script.bzl", "cargo_build_script")
load(":cargo_build_script_variants.bzl", "cargo_build_script_for_configurations")
load(":cargo_select.bzl", "cargo_select")

_LINUX = "x86_64-unknown-linux-gnu"
_MACOS = "aarch64-apple-darwin"
_WINDOWS = "x86_64-pc-windows-msvc"

def _script_definition(features, context = None, build_deps = {}):
    return {
        "crate_features_select": features,
        "build_deps_by_target": build_deps,
        "build_contexts": {triple: context or triple for triple in features} if context != "" else {},
    }

def _configured_script_loading_tests(env):
    name = "configured_build_script"
    cargo_build_script_for_configurations(
        name = name,
        configurations = {
            "": _script_definition({_LINUX: ["normal_linux"], _MACOS: ["normal_macos"]}),
            _LINUX: _script_definition({_LINUX: ["execution"], _MACOS: ["execution"]}, _LINUX),
        },
        hub_name = "rules_rs",
        crate_features = ["common"],
        tags = ["manual"],
    )
    scripts = {
        _LINUX: ({"": _LINUX}, "normal_linux"),
        _MACOS: ({"": _MACOS}, "normal_macos"),
        _LINUX + "_" + _MACOS: ({}, "execution"),
    }
    for representative, (contexts, feature) in scripts.items():
        binary = native.existing_rule(name + "_" + representative + "_")
        loadingtest.equals(env, name + "_" + representative + "_context", contexts, binary["cargo_contexts"])
        loadingtest.equals(env, name + "_" + representative + "_features", ["common", feature], list(binary["crate_features"]))
    loadingtest.equals(
        env,
        name + "_script_count",
        len(scripts),
        len([target for target in native.existing_rules() if target.startswith(name + "_") and target.endswith("_")]),
    )
    native.alias(
        name = name + "_expected",
        actual = select({
            "@rules_rs//:__cargo/normal/" + _MACOS: ":" + name + "_" + _MACOS,
            "@rules_rs//:__cargo/normal/" + _LINUX: ":" + name + "_" + _LINUX,
            "@rules_rs//:__cargo/" + _LINUX + "/" + _MACOS: ":" + name + "_" + _LINUX + "_" + _MACOS,
            "@rules_rs//:__cargo/" + _LINUX + "/" + _LINUX: ":" + name + "_" + _LINUX + "_" + _MACOS,
        }),
        tags = ["manual"],
    )
    loadingtest.equals(env, name + "_selection", str(native.existing_rule(name + "_expected")["actual"]), str(native.existing_rule(name)["actual"]))

    name = "configured_legacy_build_script"
    musl = "x86_64-unknown-linux-musl"
    cargo_build_script_for_configurations(
        name = name,
        configurations = {"": _script_definition({_LINUX: ["gnu"], musl: ["musl"], _MACOS: ["macos"]})},
        hub_name = "rules_rs",
        use_legacy_rules_rust_platforms = True,
        tags = ["manual"],
    )
    native.alias(
        name = name + "_expected",
        actual = select({
            "@rules_rs//:__cargo/normal/" + _MACOS: ":" + name + "_" + _MACOS,
            "@rules_rs//:__cargo/normal/" + musl: ":" + name + "_" + musl,
        }),
        tags = ["manual"],
    )
    loadingtest.equals(env, name + "_selection", str(native.existing_rule(name + "_expected")["actual"]), str(native.existing_rule(name)["actual"]))

    name = "single_configured_build_script"
    cargo_build_script_for_configurations(
        name = name,
        configurations = {_LINUX: _script_definition({_MACOS: []}, _LINUX)},
        hub_name = "rules_rs",
        tags = ["manual"],
    )
    binary = native.existing_rule(name + "_")
    loadingtest.equals(env, name + "_context", {}, binary["cargo_contexts"])
    loadingtest.equals(env, name + "_no_alias", False, "actual" in native.existing_rule(name))

    name = "invariant_build_script"
    definition = {
        "crate_features_select": {_LINUX: [], _MACOS: []},
        "build_deps_by_target": {},
        "build_contexts": {},
    }
    cargo_build_script_for_configurations(
        name = name,
        configurations = {"": definition, _LINUX: definition},
        hub_name = "rules_rs",
        tags = ["manual"],
    )
    loadingtest.equals(env, name + "_contexts", {_LINUX: ""}, native.existing_rule(name + "_")["cargo_contexts"])
    loadingtest.equals(env, name + "_no_alias", False, "actual" in native.existing_rule(name))

    name = "first_party_build_script"
    cargo_build_script_for_configurations(
        name = name,
        configurations = {"": definition, _LINUX: definition},
        hub_name = "rules_rs",
        preserve_context = True,
        compile_data = ["//:generated_source"],
        tags = ["manual"],
    )
    loadingtest.equals(env, name + "_normal_linux", {"": _LINUX}, native.existing_rule(name + "_" + _LINUX + "_")["cargo_contexts"])
    loadingtest.equals(env, name + "_normal_macos", {"": _MACOS}, native.existing_rule(name + "_" + _MACOS + "_")["cargo_contexts"])

    name = "execution_alias_build_script"
    cargo_build_script_for_configurations(
        name = name,
        configurations = {_LINUX: {
            "crate_features_select": {_MACOS: []},
            "build_deps_by_target": {_MACOS: {
                _MACOS: {"//:shared": "shared", "//:macos": "macos"},
                _LINUX: {"//:shared": "shared", "//:linux": "linux"},
            }},
            "build_contexts": {_MACOS: _LINUX},
        }},
        hub_name = "rules_rs",
        deps = ["//:annotation"],
        aliases = {"//:annotation": "annotated"},
        tags = ["manual"],
    )
    cargo_build_script(
        name = name + "_expected",
        aliases = select({
            "@rules_rs//rs/platforms/config:" + _MACOS: {"//:shared": "shared", "//:annotation": "annotated", "//:macos": "macos"},
            "@rules_rs//rs/platforms/config:" + _LINUX: {"//:shared": "shared", "//:annotation": "annotated", "//:linux": "linux"},
            "//conditions:default": {"//:shared": "shared", "//:annotation": "annotated"},
        }),
        tags = ["manual"],
    )
    loadingtest.equals(
        env,
        name + "_aliases",
        str(native.existing_rule(name + "_expected_")["aliases"]),
        str(native.existing_rule(name + "_")["aliases"]),
    )
    loadingtest.equals(env, name + "_annotated_context", {}, native.existing_rule(name + "_")["cargo_contexts"])

    name = "execution_alias_names_build_script"
    cargo_build_script_for_configurations(
        name = name,
        configurations = {"": _script_definition(
            {_LINUX: []},
            "",
            build_deps = {_LINUX: {
                _LINUX: {"//:shared": "linux_name", "//:unrenamed": None},
                _MACOS: {"//:shared": "macos_name", "//:unrenamed": None},
            }},
        )},
        hub_name = None,
        tags = ["manual"],
    )
    cargo_build_script(
        name = name + "_expected",
        deps = ["//:unrenamed"] + select({
            "@rules_rs//rs/platforms/config:" + _MACOS: ["//:shared"],
            "@rules_rs//rs/platforms/config:" + _LINUX: ["//:shared"],
            "//conditions:default": [],
        }),
        aliases = select({
            "@rules_rs//rs/platforms/config:" + _MACOS: {"//:shared": "macos_name"},
            "@rules_rs//rs/platforms/config:" + _LINUX: {"//:shared": "linux_name"},
            "//conditions:default": {},
        }),
        tags = ["manual"],
    )
    for field in ["deps", "aliases"]:
        loadingtest.equals(
            env,
            name + "_" + field,
            str(native.existing_rule(name + "_expected_")[field]),
            str(native.existing_rule(name + "_")[field]),
        )

    name = "cargo_select_constants"
    loadingtest.equals(env, name + "_shared", ["shared"], cargo_select({"": {_LINUX: ["shared"]}, _LINUX: {_MACOS: ["shared"]}}, "rules_rs"))
    loadingtest.equals(env, name + "_empty", [], cargo_select({}, "rules_rs", default = []))
    loadingtest.equals(env, name + "_default", {}, cargo_select({"": {_LINUX: {}}, _LINUX: {_MACOS: {}}}, "rules_rs", default = {}))

def _platform_script_loading_tests(env):
    name = "identical_build_script"
    cargo_build_script_for_configurations(
        name = name,
        configurations = {"": _script_definition(
            {_LINUX: ["a", "b"], _MACOS: ["a", "b"]},
            "",
            build_deps = {
                _LINUX: {
                    _LINUX: {"//:b": "renamed_b", "//:a": "renamed_a"},
                    _MACOS: {"//:a": "renamed_a", "//:b": "renamed_b"},
                },
                _MACOS: {
                    _MACOS: {"//:b": "renamed_b", "//:a": "renamed_a"},
                    _LINUX: {"//:a": "renamed_a", "//:b": "renamed_b"},
                },
            },
        )},
        hub_name = None,
        crate_features = ["common"],
        tags = ["manual"],
    )
    cargo_build_script(
        name = name + "_expected",
        deps = ["//:a", "//:b"],
        aliases = {"//:a": "renamed_a", "//:b": "renamed_b"},
        tags = ["manual"],
    )
    binary = native.existing_rule(name + "_")
    expected = native.existing_rule(name + "_expected_")
    loadingtest.equals(env, name + "_no_alias", False, "actual" in native.existing_rule(name))
    loadingtest.equals(env, name + "_features", ["common", "a", "b"], list(binary["crate_features"]))
    loadingtest.equals(env, name + "_deps", str(expected["deps"]), str(binary["deps"]))
    loadingtest.equals(env, name + "_aliases", expected["aliases"], binary["aliases"])
    loadingtest.equals(env, name + "_no_context", {}, dict(binary.get("cargo_contexts", {})))

    name = "feature_split_build_script"
    kwargs = {
        "tags": ["manual", "retained"],
        "rustc_flags": ["--cfg=original"],
        "rustc_env": {"KEEP": "kept"},
        "pkg_name": "original-package",
    }
    cargo_build_script_for_configurations(
        name = name,
        configurations = {"": _script_definition(
            {_LINUX: ["common", "linux"], _MACOS: ["common"], _WINDOWS: ["common"]},
            "",
            build_deps = {"": {_LINUX: {"//:helper": "renamed"}, _MACOS: {"//:helper": "renamed"}}},
        )},
        hub_name = None,
        crate_features = ["additional"],
        **kwargs
    )
    for triple, features in [(_MACOS, ["common"]), (_LINUX, ["common", "linux"])]:
        binary = native.existing_rule(name + "_" + triple + "_")
        loadingtest.equals(env, name + "_" + triple + "_features", ["additional"] + features, list(binary["crate_features"]))
        loadingtest.equals(env, name + "_" + triple + "_flags", ["--cfg=original", "--codegen=metadata=-" + triple.replace("-", "_")], list(binary["rustc_flags"]))
        loadingtest.equals(env, name + "_" + triple + "_alias", ["renamed"], list(binary["aliases"].values()))
        loadingtest.equals(env, name + "_" + triple + "_environment", "kept", binary["rustc_env"]["KEEP"])
        loadingtest.equals(env, name + "_" + triple + "_package", "original-package", binary["rustc_env"]["CARGO_PKG_NAME"])
        loadingtest.equals(env, name + "_" + triple + "_crate", name, binary["rustc_env"]["CARGO_CRATE_NAME"])
    loadingtest.equals(env, name + "_shared", None, native.existing_rule(name + "_" + _WINDOWS + "_"))
    loadingtest.equals(env, name + "_tags", kwargs["tags"], list(native.existing_rule(name)["tags"]))
    loadingtest.equals(env, name + "_input_flags", ["--cfg=original"], kwargs["rustc_flags"])
    loadingtest.equals(env, name + "_input_environment", {"KEEP": "kept"}, kwargs["rustc_env"])
    native.alias(
        name = name + "_expected",
        actual = select({
            "@rules_rs//rs/platforms/config:" + _MACOS: ":" + name + "_" + _MACOS,
            "@rules_rs//rs/platforms/config:" + _WINDOWS: ":" + name + "_" + _MACOS,
            "@rules_rs//rs/platforms/config:" + _LINUX: ":" + name + "_" + _LINUX,
        }),
        tags = ["manual"],
    )
    loadingtest.equals(env, name + "_selection", str(native.existing_rule(name + "_expected")["actual"]), str(native.existing_rule(name)["actual"]))

    for field in ["deps", "aliases"]:
        name = field + "_split_build_script"
        cargo_build_script_for_configurations(
            name = name,
            configurations = {"": _script_definition(
                {_LINUX: [], _MACOS: []},
                "",
                build_deps = {
                    "": {_LINUX: {"//:shared": "macos_name"}},
                    _LINUX: {_LINUX: {"//:shared": "linux_name"}} if field == "aliases" else {},
                },
            )},
            hub_name = None,
            tags = ["manual"],
        )
        for triple in [_LINUX, _MACOS]:
            binary = native.existing_rule(name + "_" + triple + "_")
            loadingtest.equals(env, name + "_" + triple + "_features", [], list(binary["crate_features"]))
            if field == "aliases":
                loadingtest.equals(env, name + "_" + triple, ["linux_name" if triple == _LINUX else "macos_name"], list(binary["aliases"].values()))
            else:
                loadingtest.equals(env, name + "_" + triple + "_deps", 0 if triple == _LINUX else 1, len(binary["deps"]))
        loadingtest.equals(env, name + "_split", True, "actual" in native.existing_rule(name))

    name = "host_deps_build_script"
    cargo_build_script_for_configurations(
        name = name,
        configurations = {"": _script_definition(
            {_LINUX: [], _MACOS: []},
            "",
            build_deps = {"": {
                _LINUX: {"//:shared": None, "//:linux_host": None},
                _MACOS: {"//:macos_host": None, "//:shared": None},
            }},
        )},
        hub_name = None,
        tags = ["manual"],
    )
    cargo_build_script(
        name = name + "_expected",
        deps = ["//:shared"] + select({
            "@rules_rs//rs/platforms/config:" + _MACOS: ["//:macos_host"],
            "@rules_rs//rs/platforms/config:" + _LINUX: ["//:linux_host"],
            "//conditions:default": [],
        }),
        tags = ["manual"],
    )
    loadingtest.equals(env, name + "_deps", str(native.existing_rule(name + "_expected_")["deps"]), str(native.existing_rule(name + "_")["deps"]))
    loadingtest.equals(env, name + "_shared", False, "actual" in native.existing_rule(name))

    name = "empty_build_script"
    cargo_build_script_for_configurations(
        name = name,
        configurations = {"": _script_definition({_LINUX: [], _MACOS: []}, "", build_deps = {_LINUX: {_LINUX: {}, _MACOS: {}}})},
        hub_name = None,
        tags = ["manual"],
    )
    loadingtest.equals(env, name + "_shared", False, "actual" in native.existing_rule(name))
    loadingtest.equals(env, name + "_features", [], list(native.existing_rule(name + "_")["crate_features"]))

    name = "inactive_build_script"
    cargo_build_script_for_configurations(name = name, configurations = {"": _script_definition({})}, hub_name = None, tags = ["manual"])
    loadingtest.equals(env, name + "_absent", None, native.existing_rule(name))

    name = "legacy_host_deps_build_script"
    musl = "x86_64-unknown-linux-musl"
    cargo_build_script_for_configurations(
        name = name,
        configurations = {"": _script_definition(
            {_LINUX: [], _MACOS: []},
            "",
            build_deps = {
                _LINUX: {_LINUX: {"//:gnu": None}, musl: {"//:musl": None}, _MACOS: {}},
                _MACOS: {_LINUX: {"//:musl": None, "//:gnu": None}, musl: {}, _MACOS: {}},
            },
        )},
        hub_name = None,
        use_legacy_rules_rust_platforms = True,
        tags = ["manual"],
    )
    cargo_build_script(
        name = name + "_expected",
        deps = [] + select({
            "@rules_rust//rust/platform:" + _LINUX: ["//:gnu", "//:musl"],
            "//conditions:default": [],
        }),
        tags = ["manual"],
    )
    loadingtest.equals(env, name + "_deps", str(native.existing_rule(name + "_expected_")["deps"]), str(native.existing_rule(name + "_")["deps"]))
    loadingtest.equals(env, name + "_shared", False, "actual" in native.existing_rule(name))

    name = "legacy_platform_build_script"
    cargo_build_script_for_configurations(
        name = name,
        configurations = {"": _script_definition({_MACOS: ["vendored"], _LINUX: [], musl: ["vendored"]}, "")},
        hub_name = None,
        use_legacy_rules_rust_platforms = True,
        tags = ["manual"],
    )
    native.alias(name = name + "_expected", actual = ":" + name + "_" + _MACOS, tags = ["manual"])
    loadingtest.equals(env, name + "_selection", str(native.existing_rule(name + "_expected")["actual"]), str(native.existing_rule(name)["actual"]))

def cargo_build_script_variants_tests():
    env = loadingtest.make("cargo_build_script_variants")
    _configured_script_loading_tests(env)
    _platform_script_loading_tests(env)
