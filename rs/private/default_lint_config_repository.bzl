"""Repository that exposes the toolchain-default lint_config for rules_rs."""

def _default_lint_config_repository_impl(rctx):
    if rctx.attr.lint_config:
        rctx.file(
            "BUILD.bazel",
            """\
alias(
    name = "default",
    actual = {actual},
    visibility = ["//visibility:public"],
)
""".format(actual = repr(rctx.attr.lint_config)),
        )
    else:
        rctx.file(
            "BUILD.bazel",
            """\
load("@rules_rs//rs/private:cargo_lints.bzl", "cargo_lints")

cargo_lints(
    name = "default",
    visibility = ["//visibility:public"],
)
""",
        )

    return rctx.repo_metadata(reproducible = True)

default_lint_config_repository = repository_rule(
    implementation = _default_lint_config_repository_impl,
    attrs = {
        "lint_config": attr.string(),
    },
)
