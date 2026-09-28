"""Regressions for generated crate visibility (issue #279)."""

load("@bazel_skylib//lib:unittest.bzl", "analysistest", "asserts", "unittest")
load(":visibility.bzl", "visibility_for")

def _setting(crates, visibility = ["//apps:__subpackages__"], repositories = []):
    return struct(crates = crates, visibility = visibility, repositories = repositories)

def _selection_impl(ctx):
    env = unittest.begin(ctx)
    internal = ["@hub//:__pkg__", "@spoke//:__subpackages__"]
    settings = [_setting(["framework", "framework-*"], repositories = ["hub"])]
    asserts.equals(env, ["//visibility:public"], visibility_for(settings, "other", "framework", internal))
    asserts.equals(env, ["//visibility:public"], visibility_for(settings, "hub", "frameworkish", internal))
    for crate in ["framework", "framework-macros"]:
        asserts.equals(env, ["//apps:__subpackages__"] + internal, visibility_for(settings, "hub", crate, internal))
    for visibility in [[], ["//visibility:private"]]:
        asserts.equals(env, internal, visibility_for([_setting(["framework"], visibility)], "hub", "framework", internal))
    anchored = Label("//rs/private:__pkg__")
    asserts.equals(env, [str(anchored)] + internal, visibility_for([_setting(["framework"], [anchored])], "hub", "framework", internal))
    return unittest.end(env)

_selection_test = unittest.make(_selection_impl)

def _overlap_impl(ctx):
    visibility_for([_setting(["framework"]), _setting(["framework*"])], "hub", "framework")
    return []

_overlap = rule(implementation = _overlap_impl)

def _overlap_test_impl(ctx):
    env = analysistest.begin(ctx)
    asserts.expect_failure(env, "Overlapping crate.visibility settings for framework in hub")
    return analysistest.end(env)

_overlap_test = analysistest.make(_overlap_test_impl, expect_failure = True)

def visibility_tests():
    _selection_test(name = "visibility_selection_test")
    _overlap(name = "visibility_overlap", tags = ["manual"])
    _overlap_test(name = "visibility_overlap_test", target_under_test = ":visibility_overlap")
    native.test_suite(name = "visibility_tests", tests = [":visibility_selection_test", ":visibility_overlap_test"])
