load("@bazel_skylib//lib:partial.bzl", "partial")
load("@bazel_skylib//lib:unittest.bzl", "analysistest", "asserts", "unittest")
load(":all_crate_deps.bzl", "all_crate_deps", "crate_aliases", "crate_features")
load(":cargo_select.bzl", "cargo_condition")

_LINUX = "x86_64-unknown-linux-gnu"
_MACOS = "aarch64-apple-darwin"

def _configured_data():
    return {
        "configurations": {
            "": {
                "crate_features_by_triple": {_LINUX: ["target"], _MACOS: []},
                "deps_by_triple": {_LINUX: {"@crates//:shared": "selected_shared", "//helper": "renamed_helper"}, _MACOS: {}},
                "build_deps_by_triple": {},
                "build_cargo_target_triple_required_on": [],
            },
            _LINUX: {
                "crate_features_by_triple": {_MACOS: ["exec"]},
                "deps_by_triple": {_MACOS: {"@crates//:shared": "selected_shared", "@crates//:optional": "optional", "//helper": "renamed_helper"}},
                "build_deps_by_triple": {},
                "build_cargo_target_triple_required_on": [],
            },
        },
        "dev_deps": {"@crates//:dev": "dev", "//dev": "local_dev"},
        "dev_deps_by_platform": {},
    }

def _configured_dependencies_and_features_impl(ctx):
    env = unittest.begin(ctx)
    data = _configured_data()
    asserts.equals(env, str(select({
        cargo_condition("crates", "", _MACOS): [],
        cargo_condition("crates", "", _LINUX): ["//helper", "@crates//:shared"],
        cargo_condition("crates", _LINUX, _MACOS): ["//helper", "@crates//:optional", "@crates//:shared"],
    })), str(all_crate_deps(data, hub_name = "crates")))
    asserts.equals(env, str(select({
        cargo_condition("crates", "", _MACOS): ["@crates//:dev"],
        cargo_condition("crates", "", _LINUX): ["@crates//:dev", "@crates//:shared"],
        cargo_condition("crates", _LINUX, _MACOS): ["@crates//:dev", "@crates//:optional", "@crates//:shared"],
    })), str(all_crate_deps(data, normal = True, normal_dev = True, filter_prefix = "@crates//:", hub_name = "crates")))
    asserts.equals(env, str(select({
        cargo_condition("crates", "", _MACOS): [],
        cargo_condition("crates", "", _LINUX): ["target"],
        cargo_condition("crates", _LINUX, _MACOS): ["exec"],
    })), str(crate_features(data, "crates")))
    return unittest.end(env)

def _configured_aliases_match_selected_dependencies_impl(ctx):
    env = unittest.begin(ctx)
    data = _configured_data()
    asserts.equals(env, str(select({
        cargo_condition("crates", "", _MACOS): {},
        cargo_condition("crates", "", _LINUX): {"//helper": "renamed_helper", "@crates//:shared": "selected_shared"},
        cargo_condition("crates", _LINUX, _MACOS): {"//helper": "renamed_helper", "@crates//:optional": "optional", "@crates//:shared": "selected_shared"},
    })), str(crate_aliases(data, normal = True, hub_name = "crates")))
    return unittest.end(env)

def _all_crate_deps_defaults_to_normal_impl(ctx):
    env = unittest.begin(ctx)
    data = _build_data()
    configuration = data["configurations"][""]
    configuration["deps_by_triple"] = {triple: {"//:normal": "normal"} for triple in [_LINUX, _MACOS]}
    data["dev_deps"] = {"//:dev": "dev"}

    asserts.equals(env, ["//:normal"], all_crate_deps(data, hub_name = "crates"))
    asserts.equals(env, {"//:normal": "normal"}, crate_aliases(data, hub_name = "crates"))
    return unittest.end(env)

def _all_crate_deps_dedupes_across_selected_kinds_impl(ctx):
    env = unittest.begin(ctx)
    data = _build_data()
    configuration = data["configurations"][""]
    configuration["crate_features_by_triple"] = {_LINUX: []}
    configuration["deps_by_triple"] = {_LINUX: {"@crates//:a": None, "@crates//:b": None, "//:outside": None}}
    configuration["build_deps_by_triple"] = {"": {_LINUX: {"@crates//:a": None, "@crates//:c": None}}}
    data["dev_deps"] = {"@crates//:b": None}
    data["dev_deps_by_platform"] = {"@rules_rs//rs/platforms/config:" + _LINUX: {"@crates//:a": None, "@crates//:d": None}}

    asserts.equals(env, ["@crates//:a", "@crates//:b", "@crates//:c", "@crates//:d"], all_crate_deps(
        data,
        normal = True,
        normal_dev = True,
        build = True,
        filter_prefix = "@crates//:",
        hub_name = "crates",
    ))
    return unittest.end(env)

def _legacy_platform_dev_dependencies_impl(ctx):
    env = unittest.begin(ctx)
    musl = "x86_64-unknown-linux-musl"
    data = _build_data()
    configuration = data["configurations"][""]
    configuration["crate_features_by_triple"] = {_LINUX: [], musl: []}
    configuration["deps_by_triple"] = {_LINUX: {"//:gnu": None}, musl: {"//:musl": None}}
    data["dev_deps"] = {"//:shared": None}
    data["dev_deps_by_platform"] = {"@rules_rust//rust/platform:" + _LINUX: {"//:gnu_dev": None, "//:musl_dev": None}}

    asserts.equals(env, ["//:gnu_dev", "//:musl", "//:musl_dev", "//:shared"], all_crate_deps(
        data,
        normal = True,
        normal_dev = True,
        hub_name = "crates",
        use_legacy_rules_rust_platforms = True,
    ))
    return unittest.end(env)

def _dev_dependencies_preserve_normal_aliases_impl(ctx):
    env = unittest.begin(ctx)
    data = _build_data()
    data["configurations"][""]["deps_by_triple"] = {triple: {"//:shared": "normal_name"} for triple in [_LINUX, _MACOS]}
    data["dev_deps"] = {"//:shared": None, "//:dev": "dev_name"}
    data["dev_deps_by_platform"] = {"@rules_rs//rs/platforms/config:" + _LINUX: {"//:platform": "platform_name"}}

    asserts.equals(env, str(select({
        cargo_condition("crates", "", _MACOS): {"//:dev": "dev_name", "//:shared": "normal_name"},
        cargo_condition("crates", "", _LINUX): {"//:dev": "dev_name", "//:platform": "platform_name", "//:shared": "normal_name"},
    })), str(crate_aliases(data, normal = True, normal_dev = True, hub_name = "crates")))
    return unittest.end(env)

def _build_data():
    helper = "@crates//:helper"
    return {
        "configurations": {"": {
            "crate_features_by_triple": {_LINUX: ["linux_feature"], _MACOS: ["macos_feature"]},
            "deps_by_triple": {},
            "build_deps_by_triple": {
                triple: {_LINUX: {helper: "helper"}, _MACOS: {helper: "helper"}}
                for triple in [_LINUX, _MACOS]
            },
            "build_cargo_target_triple_required_on": [],
        }},
        "dev_deps": {},
        "dev_deps_by_platform": {},
    }

def _all_crate_deps_invariant_build_deps_ignore_features_impl(ctx):
    env = unittest.begin(ctx)
    data = _build_data()
    asserts.equals(env, ["@crates//:helper"], all_crate_deps(data, build = True, hub_name = "crates"))
    asserts.equals(env, {"@crates//:helper": "helper"}, crate_aliases(data, build = True, hub_name = "crates"))
    return unittest.end(env)

def _all_crate_deps_selects_execution_platform_impl(ctx):
    env = unittest.begin(ctx)
    data = _build_data()
    deps = {_LINUX: {"@crates//:linux_helper": "helper"}, _MACOS: {"@crates//:macos_helper": "helper"}}
    for build_deps in [{triple: deps for triple in [_LINUX, _MACOS]}, {"": deps}]:
        data["configurations"][""]["build_deps_by_triple"] = build_deps
        asserts.equals(env, str(select({
            cargo_condition("crates", "", _MACOS): ["@crates//:macos_helper"],
            cargo_condition("crates", "", _LINUX): ["@crates//:linux_helper"],
        })), str(all_crate_deps(data, build = True, hub_name = "crates")))
        asserts.equals(env, str(select({
            cargo_condition("crates", "", _MACOS): {"@crates//:macos_helper": "helper"},
            cargo_condition("crates", "", _LINUX): {"@crates//:linux_helper": "helper"},
        })), str(crate_aliases(data, build = True, hub_name = "crates")))
    return unittest.end(env)

def _all_crate_deps_preserves_build_context_impl(ctx):
    env = unittest.begin(ctx)
    configuration = _build_data()["configurations"][""]
    configuration["build_cargo_target_triple_required_on"] = [_LINUX, _MACOS]
    data = {"configurations": {_LINUX: configuration}}
    asserts.equals(env, ["@crates//:helper"], all_crate_deps(data, build = True, hub_name = "crates"))
    return unittest.end(env)

def _build_aliases_ignore_unrenamed_dependencies_impl(ctx):
    env = unittest.begin(ctx)
    data = _build_data()
    configuration = data["configurations"][""]
    configuration["deps_by_triple"] = {_LINUX: {"//:linux_normal": "normal"}, _MACOS: {"//:macos_normal": "normal"}}
    configuration["build_cargo_target_triple_required_on"] = [_LINUX, _MACOS]
    configuration["build_deps_by_triple"] = {
        _LINUX: {_LINUX: {"@crates//:helper": "helper", "//:linux_build": None}, _MACOS: {"//:linux_build": None}},
        _MACOS: {_LINUX: {"@crates//:helper": "helper", "//:macos_build": None}, _MACOS: {"//:macos_build": None}},
    }
    data["dev_deps"] = {"//:dev": "dev"}
    asserts.equals(env, str(select({
        cargo_condition("crates", "", _MACOS): {},
        cargo_condition("crates", "", _LINUX): {"@crates//:helper": "helper"},
    })), str(crate_aliases(data, build = True, hub_name = "crates")))
    asserts.equals(env, str(select({
        cargo_condition("crates", "", _MACOS): {"//:dev": "dev", "//:macos_normal": "normal"},
        cargo_condition("crates", "", _LINUX): {"//:dev": "dev", "//:linux_normal": "normal", "@crates//:helper": "helper"},
    })), str(crate_aliases(data, normal = True, normal_dev = True, build = True, hub_name = "crates")))
    return unittest.end(env)

def _all_crate_deps_preserves_build_platform_domain_impl(ctx):
    env = unittest.begin(ctx)
    wasm = "wasm32-unknown-unknown"
    data = _build_data()
    configuration = data["configurations"][""]
    configuration["crate_features_by_triple"] = {wasm: []}
    configuration["deps_by_triple"] = {wasm: {"//:normal": None}}
    configuration["build_deps_by_triple"] = {wasm: {_LINUX: {"@crates//:helper": "helper"}, _MACOS: {"@crates//:helper": "helper"}}}
    asserts.equals(env, str(select({
        cargo_condition("crates", "", _MACOS): ["@crates//:helper"],
        cargo_condition("crates", "", wasm): ["//:normal"],
        cargo_condition("crates", "", _LINUX): ["@crates//:helper"],
    })), str(all_crate_deps(data, normal = True, build = True, hub_name = "crates")))
    data["dev_deps"] = {"//:dev": "renamed_dev"}
    asserts.equals(env, str(select({
        cargo_condition("crates", "", _MACOS): ["//:dev", "@crates//:helper"],
        cargo_condition("crates", "", wasm): ["//:dev", "//:normal"],
        cargo_condition("crates", "", _LINUX): ["//:dev", "@crates//:helper"],
    })), str(all_crate_deps(data, normal = True, normal_dev = True, build = True, hub_name = "crates")))
    asserts.equals(env, str(select({
        cargo_condition("crates", "", _MACOS): {"//:dev": "renamed_dev", "@crates//:helper": "helper"},
        cargo_condition("crates", "", wasm): {"//:dev": "renamed_dev"},
        cargo_condition("crates", "", _LINUX): {"//:dev": "renamed_dev", "@crates//:helper": "helper"},
    })), str(crate_aliases(data, normal = True, normal_dev = True, build = True, hub_name = "crates")))
    configuration["build_deps_by_triple"] = {wasm: {_LINUX: {}, _MACOS: {}}}
    asserts.equals(env, str(select({
        cargo_condition("crates", "", _MACOS): [],
        cargo_condition("crates", "", wasm): ["//:normal"],
        cargo_condition("crates", "", _LINUX): [],
    })), str(all_crate_deps(data, normal = True, build = True, hub_name = "crates")))
    return unittest.end(env)

def _ambiguous_build_script_impl(ctx):
    data = _build_data()
    configuration = data["configurations"][""]
    if ctx.attr.field == "aliases":
        configuration["build_deps_by_triple"] = {"": configuration["build_deps_by_triple"][_LINUX]}
        configuration["build_deps_by_triple"][_MACOS] = {_LINUX: {"@crates//:helper": "helper"}, _MACOS: {"@crates//:helper": "other_name"}}
        crate_aliases(data, build = True, hub_name = "crates")
    elif ctx.attr.field == "alias_platforms":
        configuration["build_deps_by_triple"][_MACOS][_LINUX] = {}
        crate_aliases(data, build = True, hub_name = "crates")
    elif ctx.attr.field == "cargo_target_triple":
        configuration["build_cargo_target_triple_required_on"].append(_LINUX)
        all_crate_deps(data, build = True, hub_name = "crates")
    else:
        configuration["build_deps_by_triple"][_MACOS] = {_MACOS: {"@crates//:other_helper": None}}
        all_crate_deps(data, build = True, hub_name = "crates")
    return []

_ambiguous_build_script = rule(
    implementation = _ambiguous_build_script_impl,
    attrs = {"field": attr.string()},
)

def _ambiguous_build_script_test_impl(ctx):
    env = analysistest.begin(ctx)
    asserts.expect_failure(env, "Use cargo_build_script from the generated Cargo repository's defs.bzl.")
    return analysistest.end(env)

ambiguous_build_script_test = analysistest.make(_ambiguous_build_script_test_impl, expect_failure = True)

all_crate_deps_defaults_to_normal_test = unittest.make(_all_crate_deps_defaults_to_normal_impl)
all_crate_deps_dedupes_across_selected_kinds_test = unittest.make(_all_crate_deps_dedupes_across_selected_kinds_impl)
legacy_platform_dev_dependencies_test = unittest.make(_legacy_platform_dev_dependencies_impl)
dev_dependencies_preserve_normal_aliases_test = unittest.make(_dev_dependencies_preserve_normal_aliases_impl)
all_crate_deps_invariant_build_deps_ignore_features_test = unittest.make(_all_crate_deps_invariant_build_deps_ignore_features_impl)
all_crate_deps_selects_execution_platform_test = unittest.make(_all_crate_deps_selects_execution_platform_impl)
all_crate_deps_preserves_build_context_test = unittest.make(_all_crate_deps_preserves_build_context_impl)
all_crate_deps_preserves_build_platform_domain_test = unittest.make(_all_crate_deps_preserves_build_platform_domain_impl)
build_aliases_ignore_unrenamed_dependencies_test = unittest.make(_build_aliases_ignore_unrenamed_dependencies_impl)
configured_dependencies_and_features_test = unittest.make(_configured_dependencies_and_features_impl)
configured_aliases_match_selected_dependencies_test = unittest.make(_configured_aliases_match_selected_dependencies_impl)

def all_crate_deps_tests():
    for field in ["aliases", "alias_platforms", "cargo_target_triple", "deps"]:
        _ambiguous_build_script(
            name = "ambiguous_build_script_" + field,
            field = field,
            tags = ["manual"],
        )
    return unittest.suite(
        "all_crate_deps_tests",
        all_crate_deps_defaults_to_normal_test,
        all_crate_deps_dedupes_across_selected_kinds_test,
        legacy_platform_dev_dependencies_test,
        dev_dependencies_preserve_normal_aliases_test,
        all_crate_deps_invariant_build_deps_ignore_features_test,
        all_crate_deps_selects_execution_platform_test,
        all_crate_deps_preserves_build_context_test,
        all_crate_deps_preserves_build_platform_domain_test,
        build_aliases_ignore_unrenamed_dependencies_test,
        configured_dependencies_and_features_test,
        configured_aliases_match_selected_dependencies_test,
        partial.make(ambiguous_build_script_test, target_under_test = ":ambiguous_build_script_deps"),
        partial.make(ambiguous_build_script_test, target_under_test = ":ambiguous_build_script_aliases"),
        partial.make(ambiguous_build_script_test, target_under_test = ":ambiguous_build_script_alias_platforms"),
        partial.make(ambiguous_build_script_test, target_under_test = ":ambiguous_build_script_cargo_target_triple"),
    )
