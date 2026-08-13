"""Public Rust test rules and reusable Cargo-style test suites."""

load(
    "@rules_rust//rust:defs.bzl",
    _rust_test = "rust_test",
    _rust_test_suite = "rust_test_suite",
)

rust_test = _rust_test
rust_test_suite = _rust_test_suite

def _sanitize_test_name(name):
    for character in ["-", "/", ".", ":"]:
        name = name.replace(character, "_")
    return name

def _label_name(label):
    label = str(label)
    if ":" in label:
        return label.rsplit(":", 1)[1]
    return label.rsplit("/", 1)[-1]

def _test_suite(name, tests, tags, visibility):
    kwargs = {
        "name": name,
        "tags": tags,
        "tests": tests,
    }
    if visibility != None:
        kwargs["visibility"] = visibility
    native.test_suite(**kwargs)

def rust_unit_test_suite(name, crates, deps = [], tags = [], visibility = None, **kwargs):
    """Creates one unit-test target for each existing Rust library or binary.

    Each generated target uses `rust_test(crate = ...)`, so its sources,
    edition, aliases, and existing dependencies come from the referenced Rust
    target. Additional `deps` are available to code behind `#[cfg(test)]`.
    Generated target names are `<name>_<sanitized-crate-target>_test`.

    Args:
        name: Name of the generated Bazel `test_suite`.
        crates: Existing Rust library, proc-macro, or binary target labels.
        deps: Additional dependencies for every generated unit test.
        tags: Tags applied to the generated tests and the generated suite.
        visibility: Optional visibility for the generated tests and suite.
        **kwargs: Additional `rust_test` attributes, such as `aliases`,
            `crate_features`, `data`, `rustc_env`, `args`, and `timeout`.
            `srcs` and `crate_root` cannot be used with `crate`.
    """
    suite_tags = ["restrict_" + _sanitize_test_name(name)] + tags
    tests = []
    seen = {}

    for crate in crates:
        test_name = name + "_" + _sanitize_test_name(_label_name(crate)) + "_test"
        if test_name in seen:
            if seen[test_name] != str(crate):
                fail("rust_unit_test_suite %s has conflicting crates %s and %s" % (
                    name,
                    seen[test_name],
                    crate,
                ))
            continue

        test_kwargs = dict(kwargs)
        test_kwargs.update({
            "crate": crate,
            "deps": deps,
            "name": test_name,
            "tags": suite_tags,
        })
        if visibility != None:
            test_kwargs["visibility"] = visibility
        rust_test(**test_kwargs)

        seen[test_name] = str(crate)
        tests.append(test_name)

    _test_suite(name, tests, suite_tags, visibility)

def rust_integration_test_suite(
        name,
        srcs,
        shared_srcs = [],
        deps = [],
        binaries = [],
        data = [],
        tags = [],
        visibility = None,
        **kwargs):
    """Creates one integration-test target for each distinct Rust test root.

    Sources listed in `shared_srcs` are included in every generated test but
    are never treated as test roots. Binary labels are added to each test's
    runfiles and exposed through Cargo-compatible `CARGO_BIN_EXE_<name>`
    compile-time and runtime environment variables. A trailing `__bin` on a
    binary target name is removed from the environment-variable name.
    Generated target names are `<name>_<sanitized-source-without-.rs>_test`.

    Args:
        name: Name of the generated Bazel `test_suite`.
        srcs: Rust integration-test roots, typically `glob(["tests/*.rs"])`.
        shared_srcs: Rust source files shared by the integration-test roots.
        deps: Dependencies for every generated integration test.
        binaries: Binary labels available to integration tests.
        data: Additional runfiles for every generated integration test.
        tags: Tags applied to the generated tests and the generated suite.
        visibility: Optional visibility for the generated tests and suite.
        **kwargs: Additional `rust_test` attributes, such as `aliases`,
            `edition`, `crate_features`, `compile_data`, `rustc_env`, `env`,
            `args`, and `timeout`. Explicit `rustc_env` and `env` values
            override generated `CARGO_BIN_EXE_<name>` values.
    """
    suite_tags = ["restrict_" + _sanitize_test_name(name)] + tags
    shared_sources = {}
    for source in shared_srcs:
        shared_sources[str(source)] = True

    cargo_binary_env = {}
    for binary in binaries:
        binary_name = _label_name(binary)
        if binary_name.endswith("__bin"):
            binary_name = binary_name[:-len("__bin")]
        cargo_binary_env["CARGO_BIN_EXE_" + binary_name] = "$(rootpath %s)" % binary

    caller_rustc_env = kwargs.pop("rustc_env", {})
    caller_env = kwargs.pop("env", {})

    rustc_env = dict(cargo_binary_env)
    rustc_env.update(caller_rustc_env)
    env = dict(cargo_binary_env)
    env.update(caller_env)

    tests = []
    seen = {}
    for source in srcs:
        source_name = str(source)
        if not source_name.endswith(".rs"):
            fail("rust_integration_test_suite srcs should have `.rs` extensions: %s" % source)
        if source_name in shared_sources:
            continue

        test_name = name + "_" + _sanitize_test_name(source_name[:-3]) + "_test"
        if test_name in seen:
            if seen[test_name] != source_name:
                fail("rust_integration_test_suite %s has conflicting sources %s and %s" % (
                    name,
                    seen[test_name],
                    source,
                ))
            continue

        test_kwargs = dict(kwargs)
        test_kwargs.update({
            "crate_name": _sanitize_test_name(test_name),
            "crate_root": source,
            "data": data + binaries,
            "deps": deps,
            "env": env,
            "name": test_name,
            "rustc_env": rustc_env,
            "srcs": [source] + shared_srcs,
            "tags": suite_tags,
        })
        if visibility != None:
            test_kwargs["visibility"] = visibility
        rust_test(**test_kwargs)

        seen[test_name] = source_name
        tests.append(test_name)

    _test_suite(name, tests, suite_tags, visibility)
