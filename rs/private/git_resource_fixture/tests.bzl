"""Check invalid resource link diagnostics without fetching a broken repository."""

load("@bazel_skylib//lib:unittest.bzl", "analysistest", "asserts")
load("//rs/private:git_workspace_resources.bzl", "validate_resource_path")

def _invalid_impl(ctx):
    validate_resource_path("/checkout", ctx.attr.real, "/checkout/link", ["/checkout", "/checkout/parent"], True)
    return []

_invalid = rule(implementation = _invalid_impl, attrs = {"real": attr.string()})

def _failure_impl(ctx):
    env = analysistest.begin(ctx)
    asserts.expect_failure(env, ctx.attr.message)
    return analysistest.end(env)

_failure_test = analysistest.make(_failure_impl, expect_failure = True, attrs = {"message": attr.string()})

def resource_failure_tests():
    for name, real, message in [("outside", "/elsewhere", "escapes its repository"), ("prefix", "/checkout-other/file", "escapes its repository"), ("cycle", "/checkout/parent", "directory link cycle")]:
        _invalid(name = name, real = real, tags = ["manual"])
        _failure_test(name = name + "_test", target_under_test = ":" + name, message = message)
