"""Generated selectors keep value conversion, platform labels and defaults."""

load("@bazel_skylib//lib:unittest.bzl", "asserts", "unittest")
load(":select_render.bzl", "render_select", "render_select_build_script_env")

def _render_lists_impl(ctx):
    env = unittest.begin(ctx)
    asserts.equals(env, (["common", "42"], ""), render_select(["common", 42], {}, False))
    for legacy, platform in [
        (False, "@rules_rs//rs/platforms/config:x86_64-unknown-linux-musl"),
        (True, "@rules_rust//rust/platform:x86_64-unknown-linux-gnu"),
    ]:
        common, selected = render_select(
            ["//:common"],
            {
                "x86_64-unknown-linux-musl": ["//:linux", "//:common", "//:linux"],
                "aarch64-apple-darwin": [],
            },
            legacy,
        )
        asserts.equals(env, ["//:common"], common)
        asserts.equals(env, """select({
        "%s": ["//:linux"],
        "//conditions:default": [],
    })""" % platform, selected)
    return unittest.end(env)

def _render_environment_impl(ctx):
    env = unittest.begin(ctx)
    asserts.equals(env, "", render_select_build_script_env({}, False))
    asserts.equals(env, """select({
        "@rules_rust//rust/platform:x86_64-pc-windows-msvc": {"MODE": "windows"},
        "@rules_rust//rust/platform:x86_64-unknown-linux-gnu": {"MODE": "linux"},
        "//conditions:default": {},
    })""", render_select_build_script_env({
        "x86_64-pc-windows-gnullvm": '{"MODE": "windows"}',
        "x86_64-unknown-linux-musl": '{"MODE": "linux"}',
    }, True))
    return unittest.end(env)

_render_lists_test = unittest.make(_render_lists_impl)
_render_environment_test = unittest.make(_render_environment_impl)

def select_render_tests():
    unittest.suite(
        "select_render_tests",
        _render_lists_test,
        _render_environment_test,
    )
