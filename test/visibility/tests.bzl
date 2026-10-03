"""Verify visibility with real generated targets and consumer packages."""

load("@bazel_skylib//lib:unittest.bzl", "analysistest", "asserts")

def _denied_impl(ctx):
    env = analysistest.begin(ctx)
    asserts.expect_failure(env, "is not visible from")
    return analysistest.end(env)

_denied_test = analysistest.make(_denied_impl, expect_failure = True)

def visibility_denied_tests():
    for name, actual in [("lib", "@visibility_lib//:sample"), ("bin", "@visibility_lib//:probe__bin"), ("macro", "@visibility_macro//:sample"), ("hub", "@visibility_hub//:itoa"), ("versioned", "@visibility_hub//:itoa-1.0.18"), ("extra_alias", "@visibility_hub//:itoa_metadata"), ("versioned_extra_alias", "@visibility_hub//:itoa_metadata-1.0.18"), ("spoke", "@visibility_hub__itoa-1.0.18//:itoa"), ("private", "@visibility_private//:visibility_private"), ("empty", "@visibility_empty//:visibility_empty")]:
        native.filegroup(name = name, srcs = [actual], tags = ["manual"])
        _denied_test(name = name + "_test", target_under_test = ":" + name)
