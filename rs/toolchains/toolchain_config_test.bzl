"""Tests for toolchain declarations from multiple modules."""

load("@bazel_skylib//lib:unittest.bzl", "analysistest", "asserts", "unittest")
load(":toolchain_config.bzl", "resolve_toolchain_configs")

def _tag(**kwargs):
    attrs = dict(
        name = "default_rust_toolchains",
        version = "1.92.0",
        edition = "2021",
        rustfmt_version = "",
        rust_analyzer_version = "",
        extra_rustc_flags = {},
        extra_exec_rustc_flags = {},
        use_rust_redist = True,
    )
    attrs.update(kwargs)
    return struct(**attrs)

def _module(*tags, **kwargs):
    return struct(is_root = kwargs.get("is_root", False), tags = struct(toolchain = tags))

def _resolve(*modules):
    return resolve_toolchain_configs(modules)["default_rust_toolchains"]

def _root_override_impl(ctx):
    env = unittest.begin(ctx)
    root = _module(_tag(version = "1.85.0", edition = "2018"), is_root = True)
    deps = [
        _module(_tag(version = "nightly/2026-01-01", extra_rustc_flags = {"*": ["-Zfoo"]}, use_rust_redist = False)),
        _module(_tag(version = "1.99.0", edition = "2024", rustfmt_version = "beta/2026-02-01")),
    ]
    for modules in [[root] + deps, deps + [root]]:
        config = _resolve(*modules)
        asserts.equals(env, "1.85.0", config.version)
        asserts.equals(env, "2018", config.edition)
        asserts.equals(env, "1.85.0", config.rustfmt_version)
        asserts.equals(env, "1.85.0", config.rust_analyzer_version)
        asserts.equals(env, {}, config.extra_rustc_flags)
        asserts.true(env, config.use_rust_redist)
    return unittest.end(env)

def _dependency_maxima_impl(ctx):
    env = unittest.begin(ctx)
    a = _module(_tag(version = "1.99.0", edition = "2024", rustfmt_version = "1.101.0", use_rust_redist = False))
    b = _module(_tag(version = "1.100.0", edition = "2021", rust_analyzer_version = "1.102.0"))
    for modules in [(a, b), (b, a)]:
        config = _resolve(*modules)
        asserts.equals(env, "1.100.0", config.version)
        asserts.equals(env, "2024", config.edition)
        asserts.equals(env, "1.101.0", config.rustfmt_version)
        asserts.equals(env, "1.102.0", config.rust_analyzer_version)
        asserts.false(env, config.use_rust_redist)
    config = _resolve(_module(_tag(version = "1.92.9")), _module(_tag(version = "1.92.10")))
    asserts.equals(env, "1.92.10", config.version)
    asserts.equals(env, "1.92.10", config.rustfmt_version)
    asserts.equals(env, "1.92.10", config.rust_analyzer_version)
    return unittest.end(env)

def _dated_versions_impl(ctx):
    env = unittest.begin(ctx)
    for channel in ["beta", "nightly"]:
        for dates in [("2025-12-31", "2026-01-01"), ("2026-01-01", "2025-12-31")]:
            config = _resolve(*[_module(_tag(version = "%s/%s" % (channel, date))) for date in dates])
            asserts.equals(env, channel + "/2026-01-01", config.version)
            asserts.equals(env, config.version, config.rustfmt_version)
            asserts.equals(env, config.version, config.rust_analyzer_version)
    return unittest.end(env)

def _separate_names_impl(ctx):
    env = unittest.begin(ctx)
    configs = resolve_toolchain_configs([
        _module(_tag(version = "1.85.0"), is_root = True),
        _module(_tag(version = "1.99.0"), _tag(name = "other", version = "nightly/2026-01-01")),
    ])
    asserts.equals(env, ["default_rust_toolchains", "other"], configs.keys())
    asserts.equals(env, "1.85.0", configs["default_rust_toolchains"].version)
    asserts.equals(env, "nightly/2026-01-01", configs["other"].version)
    asserts.equals(env, {}, resolve_toolchain_configs([_module(is_root = True)]))
    return unittest.end(env)

def _duplicate_tags_impl(ctx):
    env = unittest.begin(ctx)
    tag = _tag(extra_exec_rustc_flags = {"*": ["-Copt-level=1"]})
    explicit = _tag(rustfmt_version = tag.version, rust_analyzer_version = tag.version, extra_exec_rustc_flags = tag.extra_exec_rustc_flags)
    for is_root in [False, True]:
        config = _resolve(_module(tag, explicit, is_root = is_root))
        asserts.equals(env, tag.version, config.version)
        asserts.equals(env, tag.extra_exec_rustc_flags, config.extra_exec_rustc_flags)
    return unittest.end(env)

def _conflicting_config_impl(ctx):
    other = _tag(**json.decode(ctx.attr.other))
    resolve_toolchain_configs([_module(_tag(), other, is_root = ctx.attr.is_root)])
    return []

_conflicting_config = rule(
    implementation = _conflicting_config_impl,
    attrs = {
        "other": attr.string(),
        "is_root": attr.bool(),
    },
)

def _conflict_test_impl(ctx):
    env = analysistest.begin(ctx)
    asserts.expect_failure(env, ctx.attr.message)
    return analysistest.end(env)

_conflict_test = analysistest.make(
    _conflict_test_impl,
    expect_failure = True,
    attrs = {"message": attr.string()},
)

_root_override_test = unittest.make(_root_override_impl)
_dependency_maxima_test = unittest.make(_dependency_maxima_impl)
_dated_versions_test = unittest.make(_dated_versions_impl)
_separate_names_test = unittest.make(_separate_names_impl)
_duplicate_tags_test = unittest.make(_duplicate_tags_impl)

def toolchain_config_tests(name):
    """Declare toolchain configuration tests.

    Args:
        name: Test suite name.
    """
    unittest.suite(
        name + "_success",
        _root_override_test,
        _dependency_maxima_test,
        _dated_versions_test,
        _separate_names_test,
        _duplicate_tags_test,
    )
    tests = [name + "_success"]
    for suffix, other, is_root, message in [
        ("root", {"version": "1.99.0"}, True, "conflicting tag configurations in the root module"),
        ("channel", {"version": "nightly/2026-01-01"}, False, "incomparable version values"),
        ("rustfmt", {"rustfmt_version": "beta/2026-01-01"}, False, "incomparable rustfmt_version values"),
        ("analyzer", {"rust_analyzer_version": "nightly/2026-01-01"}, False, "incomparable rust_analyzer_version values"),
        ("flags", {"extra_rustc_flags": {"*": ["-Copt-level=1"]}}, False, "conflicting extra_rustc_flags"),
        ("exec_flags", {"extra_exec_rustc_flags": {"*": ["-Copt-level=1"]}}, False, "conflicting extra_exec_rustc_flags"),
    ]:
        target = name + "_" + suffix
        _conflicting_config(
            name = target,
            other = json.encode(other),
            is_root = is_root,
            tags = ["manual"],
        )
        _conflict_test(
            name = target + "_test",
            target_under_test = ":" + target,
            message = message,
        )
        tests.append(target + "_test")
    native.test_suite(name = name, tests = tests)
