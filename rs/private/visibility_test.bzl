"""Regressions for generated crate visibility (issue #279)."""

load("@bazel_skylib//lib:unittest.bzl", "asserts", "unittest")
load(":visibility.bzl", "visibility_with_internal_access")

def _internal_access_impl(ctx):
    env = unittest.begin(ctx)
    internal = ["@hub//:__pkg__", "@spoke//:__subpackages__"]
    for visibility in [["//visibility:public"], [Label("//visibility:public")]]:
        asserts.equals(env, ["//visibility:public"], visibility_with_internal_access(visibility, internal))
    for visibility in [[], ["//visibility:private"], [Label("//visibility:private")]]:
        asserts.equals(env, internal, visibility_with_internal_access(visibility, internal))
    anchored = Label("//rs/private:__pkg__")
    asserts.equals(env, [str(anchored)] + internal, visibility_with_internal_access([anchored], internal))
    return unittest.end(env)

_internal_access_test = unittest.make(_internal_access_impl)

def visibility_tests():
    unittest.suite("visibility_tests", _internal_access_test)
