"""Tests for generated rust_crate calls."""

load("@bazel_skylib//lib:unittest.bzl", "asserts", "unittest")
load(":repository_utils.bzl", "render_rust_crate_call")

def _render_with_rustc_flags(flags, conditional_flags, use_legacy = False):
    attr = struct(
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
        data = [],
        deps = [],
        deps_select = {},
        rustc_flags = flags,
        rustc_flags_select = conditional_flags,
        use_legacy_rules_rust_platforms = use_legacy,
    )
    values = {
        "binaries": {},
        "build_script": None,
        "crate_name": "example",
        "crate_root": "src/lib.rs",
        "edition": "2021",
        "has_lib": True,
        "is_proc_macro": False,
        "links": None,
        "name": "example",
        "purl": "pkg:cargo/example@1.0.0",
        "version": "1.0.0",
    }
    return render_rust_crate_call(attr, {key: repr(value) for key, value in values.items()})

def _rustc_flags_preserve_order_test_impl(ctx):
    env = unittest.begin(ctx)
    common = ["-C", "opt-level=3", "-C", "target-cpu=generic"]
    linux = ["--cfg", "linux_first", "--cfg", "linux_second"]
    macos = ["--cfg", "macos_first", "--cfg", "macos_second"]
    rendered = _render_with_rustc_flags(common, {
        "aarch64-apple-darwin": macos,
        "x86_64-unknown-linux-gnu": linux,
    })
    asserts.true(env, "rustc_flags = " + repr(common) + " + select({" in rendered, rendered)
    asserts.true(env, '"@rules_rs//rs/platforms/config:x86_64-unknown-linux-gnu": ' + repr(linux) in rendered, rendered)
    asserts.true(env, '"@rules_rs//rs/platforms/config:aarch64-apple-darwin": ' + repr(macos) in rendered, rendered)
    return unittest.end(env)

def _rustc_flags_stay_conditional_test_impl(ctx):
    env = unittest.begin(ctx)
    linux = ["--cfg=linux_only"]
    for legacy in (False, True):
        rendered = _render_with_rustc_flags([], {"x86_64-unknown-linux-gnu": linux}, use_legacy = legacy)
        platform = "@rules_rust//rust/platform:x86_64-unknown-linux-gnu" if legacy else "@rules_rs//rs/platforms/config:x86_64-unknown-linux-gnu"
        asserts.true(env, "rustc_flags = [] + select({" in rendered, rendered)
        asserts.true(env, '"' + platform + '": ' + repr(linux) in rendered, rendered)
        asserts.true(env, '"//conditions:default": []' in rendered, rendered)
    return unittest.end(env)

_rustc_flags_preserve_order_test = unittest.make(_rustc_flags_preserve_order_test_impl)
_rustc_flags_stay_conditional_test = unittest.make(_rustc_flags_stay_conditional_test_impl)

def repository_utils_tests():
    return unittest.suite(
        "repository_utils_tests",
        _rustc_flags_preserve_order_test,
        _rustc_flags_stay_conditional_test,
    )
